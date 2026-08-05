"""ONNX export + mandatory numerical-parity validation. No exported file
is considered trustworthy until this validation passes - catches silent
conversion bugs (feature-order mismatch, missing scaling, category-handling
differences) before the file ever reaches MQL5."""
import numpy as np
import onnxruntime as ort
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType


def export_sklearn_model(model, feature_cols, opset=15):
    """Returns the ONNX model bytes. zipmap=False is a known skl2onnx
    gotcha - without it, output is a list-of-dict, not a plain float
    tensor, which OnnxRun on the MQL5 side cannot consume directly."""
    initial_type = [("input", FloatTensorType([None, len(feature_cols)]))]
    onnx_model = convert_sklearn(
        model, initial_types=initial_type, target_opset=opset,
        options={id(model): {"zipmap": False}},
    )
    return onnx_model.SerializeToString()


def validate_onnx(onnx_bytes, sklearn_model, X_sample, tolerance=1e-5):
    """Reloads the exported bytes via onnxruntime and diffs its output
    against the original sklearn model's predict_proba on the same rows.
    Raises AssertionError if they don't match within tolerance."""
    X = np.ascontiguousarray(X_sample.to_numpy(dtype=np.float32))
    sess = ort.InferenceSession(onnx_bytes, providers=["CPUExecutionProvider"])
    input_name = sess.get_inputs()[0].name
    outputs = sess.run(None, {input_name: X})

    # skl2onnx with zipmap=False typically returns [labels, probabilities]
    # for a classifier - take the probabilities output (2D, one column per
    # class).
    prob_output = None
    for out in outputs:
        if out.ndim == 2 and out.shape[1] >= 2:
            prob_output = out
            break
    if prob_output is None:
        raise RuntimeError(f"Could not find a probability-shaped output among: {[o.shape for o in outputs]}")

    onnx_prob_positive = prob_output[:, 1]
    sklearn_prob_positive = sklearn_model.predict_proba(X_sample)[:, 1]

    max_diff = np.max(np.abs(onnx_prob_positive - sklearn_prob_positive))
    assert max_diff < tolerance, (
        f"ONNX output diverges from source sklearn model by {max_diff} "
        f"(tolerance {tolerance}) - DO NOT ship this .onnx file."
    )
    return max_diff
