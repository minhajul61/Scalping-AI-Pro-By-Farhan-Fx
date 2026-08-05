import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))
sys.path.insert(0, str(ROOT_DIR / "src"))

import json
import joblib
import pandas as pd

from config import settings
from dca_ml.modeling.train_stuck_model import FEATURE_COLS as STUCK_FEATURE_COLS
from dca_ml.export.export_onnx import export_sklearn_model, validate_onnx
from dca_ml.util.logging_setup import get_logger

log = get_logger("run_export_onnx")


def main():
    model_dir = settings.MODELS_DIR / "stuck_basket_risk" / "v1"
    metadata_path = model_dir / "metadata.json"
    with open(metadata_path) as f:
        metadata = json.load(f)

    if not metadata.get("shipped"):
        log.warning(f"Model not marked as shipped in {metadata_path} - skipping ONNX export. "
                    f"Conclusion was: {metadata.get('conclusion')}")
        return

    model = joblib.load(model_dir / "model.joblib")
    log.info(f"Loaded model: {metadata['best_model_name']}, holdout AUC={metadata['holdout_metrics']['auc']:.4f}")

    # Use a slice of the labeled data as the validation sample for the
    # ONNX round-trip check (doesn't need to be the holdout specifically -
    # this is just verifying the FILE matches the model, not re-evaluating
    # performance).
    labeled = pd.read_parquet(settings.DATA_PROCESSED_DIR / "stuck_labeled.parquet")
    labeled = labeled.copy()
    labeled["is_against_trend_now"] = labeled["is_against_trend_now"].astype(int)
    labeled["is_atr_spiking_now"] = labeled["is_atr_spiking_now"].astype(int)
    regime_dummies = pd.get_dummies(labeled["regime"], prefix="regime")
    for col in ("regime_RANGING", "regime_TRENDING", "regime_VOLATILE"):
        if col not in regime_dummies.columns:
            regime_dummies[col] = 0
    labeled = pd.concat([labeled, regime_dummies], axis=1)
    X_sample = labeled[STUCK_FEATURE_COLS].astype("float32").head(500)

    onnx_bytes = export_sklearn_model(model, STUCK_FEATURE_COLS, opset=settings.ONNX_OPSET)
    max_diff = validate_onnx(onnx_bytes, model, X_sample, tolerance=settings.ONNX_VALIDATION_TOLERANCE)
    log.info(f"ONNX round-trip validated: max diff vs source model = {max_diff:.2e} "
             f"(tolerance {settings.ONNX_VALIDATION_TOLERANCE}) - PASSED")

    onnx_path = model_dir / "model.onnx"
    with open(onnx_path, "wb") as f:
        f.write(onnx_bytes)
    log.info(f"Saved validated ONNX model to {onnx_path} ({len(onnx_bytes)} bytes)")

    # Also write the feature order/spec alongside the model - the MQL5 side
    # must build its feature vector in EXACTLY this order.
    spec = dict(feature_cols=STUCK_FEATURE_COLS, model_type=metadata["best_model_name"],
                holdout_auc=metadata["holdout_metrics"]["auc"])
    with open(model_dir / "onnx_input_spec.json", "w") as f:
        json.dump(spec, f, indent=2)
    log.info(f"Saved feature spec to {model_dir / 'onnx_input_spec.json'}")


if __name__ == "__main__":
    main()
