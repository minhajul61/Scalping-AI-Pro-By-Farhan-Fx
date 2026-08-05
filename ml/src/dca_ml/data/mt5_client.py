"""Connect/verify/shutdown helper. Same account-mismatch safety check as the
sibling project's mt5_client.py: mt5.initialize() with no explicit login
just attaches to whatever account the already-running terminal happens to
be logged into, which is how a script can silently pull data from (or,
worse, trade) the wrong account."""
import MetaTrader5 as mt5

from config import settings
from dca_ml.util.logging_setup import get_logger

log = get_logger("mt5_client")


class AccountMismatchError(RuntimeError):
    pass


def connect(verify_account=True):
    ok = mt5.initialize(
        path=settings.MT5_TERMINAL_PATH,
        login=settings.MT5_LOGIN,
        password=settings.MT5_PASSWORD,
        server=settings.MT5_SERVER,
    )
    if not ok:
        raise RuntimeError(f"mt5.initialize failed: {mt5.last_error()}")

    if verify_account:
        info = mt5.account_info()
        if info is None:
            mt5.shutdown()
            raise RuntimeError("mt5.account_info() returned None after connect")
        if info.login != settings.EXPECTED_ACCOUNT:
            mt5.shutdown()
            raise AccountMismatchError(
                f"Connected to account {info.login} but expected "
                f"{settings.EXPECTED_ACCOUNT}. Refusing to proceed."
            )
        log.info(f"Connected to account {info.login} ({info.server}), equity={info.equity}")

    if not mt5.symbol_select(settings.SYMBOL, True):
        mt5.shutdown()
        raise RuntimeError(f"symbol_select failed for {settings.SYMBOL}: {mt5.last_error()}")

    return mt5


def shutdown():
    mt5.shutdown()
