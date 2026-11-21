"""TLS and mutual-TLS material for every service, from files or environment.

Why mTLS lives at the TLS layer instead of in the request handler: a client
certificate is verified during the handshake, before a single HTTP byte is
parsed, so an unauthenticated caller cannot reach the router, the body parser or
the database dependency. It also works identically under Docker Compose, ECS and
Kubernetes without a service mesh.

Credentials arrive in one of two shapes:
  * files    -- TLS_CERT_FILE, TLS_KEY_FILE, ... (Kubernetes secret volumes),
  * PEM text -- TLS_CERT_PEM, TLS_KEY_PEM, ... (ECS task environment, where the
    execution role resolves Secrets Manager into environment variables).
PEM text is written to a 0600 file under a private temp directory because
uvicorn's SSL context requires paths, and an emptyDir/read-only root filesystem
is exactly the place to put them.
"""

from __future__ import annotations

import logging
import os
import ssl
import tempfile
from pathlib import Path

log = logging.getLogger(__name__)

_materialized_dir: Path | None = None


def _materialize(pem: str, name: str) -> str:
    """Write a PEM block to a private file and return its path."""
    global _materialized_dir
    if _materialized_dir is None:
        _materialized_dir = Path(tempfile.mkdtemp(prefix="showcase-tls-"))
        _materialized_dir.chmod(0o700)
    path = _materialized_dir / name
    path.write_text(pem.replace("\\n", "\n"), encoding="utf-8")
    path.chmod(0o600)
    return str(path)


def _lookup(file_env: str, pem_env: str, name: str) -> str | None:
    """Prefer a mounted file; fall back to an inline PEM environment variable."""
    path = os.getenv(file_env)
    if path:
        return path
    pem = os.getenv(pem_env)
    return _materialize(pem, name) if pem else None


def _client_ca() -> str | None:
    """Trust bundle for inbound client certificates.

    Three shapes, in order of preference:
      * TLS_CLIENT_CA_DIR -- one file per *allowed caller identity*, mounted separately
        (a projected volume). Adding a caller means adding its CA to the server's mounts,
        which makes the allow rule reviewable on its own;
      * TLS_CLIENT_CA_FILE -- one file that already concatenates every allowed issuer;
      * TLS_CLIENT_CA_PEM -- inline text, for the ECS task environment.
    A directory that contains no certificates is an error, not a silent downgrade: a
    server that trusts nothing would reject every caller, and one that trusts everything
    would defeat the point.
    """
    directory = os.getenv("TLS_CLIENT_CA_DIR")
    if directory:
        files = sorted(
            path for path in Path(directory).iterdir() if path.suffix in {".crt", ".pem"}
        )
        if not files:
            raise ValueError(f"TLS_CLIENT_CA_DIR={directory} contains no *.crt files")
        bundle = "".join(path.read_text(encoding="utf-8") for path in files)
        log.info(
            "inbound client trust: %d CA(s) from %s (%s)",
            len(files),
            directory,
            ", ".join(path.stem for path in files),
        )
        return _materialize(bundle, "client-ca-bundle.crt")
    return _lookup("TLS_CLIENT_CA_FILE", "TLS_CLIENT_CA_PEM", "client-ca.crt")


def server_ssl_kwargs() -> dict[str, object] | None:
    """Keyword arguments for uvicorn's data listener, or None for plain HTTP.

    When a client CA is configured the listener demands a certificate signed by
    it (CERT_REQUIRED). Set TLS_REQUIRE_CLIENT_CERT=0 for a one-way TLS listener,
    which is only useful for debugging: the platform expects mutual auth.
    """
    cert = _lookup("TLS_CERT_FILE", "TLS_CERT_PEM", "tls.crt")
    key = _lookup("TLS_KEY_FILE", "TLS_KEY_PEM", "tls.key")
    if not cert or not key:
        return None

    ca = _client_ca()
    require_client_cert = os.getenv("TLS_REQUIRE_CLIENT_CERT", "1") != "0"

    kwargs: dict[str, object] = {"ssl_certfile": cert, "ssl_keyfile": key}
    if ca:
        kwargs["ssl_ca_certs"] = ca
        kwargs["ssl_cert_reqs"] = ssl.CERT_REQUIRED if require_client_cert else ssl.CERT_OPTIONAL
        log.info("mTLS enabled: client certificates required=%s", require_client_cert)
    else:
        log.warning("TLS enabled without a client CA: this listener is not mutual TLS")
    return kwargs


def client_ssl_context() -> ssl.SSLContext | None:
    """Outbound context that verifies the server *and* presents a client cert.

    Hostname checking stays on (the service DNS name is in the certificate SANs),
    which is what stops a valid certificate for another service being replayed.
    Returns None when no CA is configured, so local plain-HTTP development keeps
    working without special cases in the callers.
    """
    ca = _lookup("TLS_CA_FILE", "TLS_CA_PEM", "ca.crt")
    if not ca:
        return None

    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=ca)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED

    cert = _lookup("TLS_CLIENT_CERT_FILE", "TLS_CLIENT_CERT_PEM", "client.crt")
    key = _lookup("TLS_CLIENT_KEY_FILE", "TLS_CLIENT_KEY_PEM", "client.key")
    if cert and key:
        context.load_cert_chain(cert, key)
        log.info("outbound mTLS enabled: client certificate loaded")
    else:
        log.warning("outbound TLS enabled without a client certificate: upstreams will reject us")
    return context


def peer_identity_hint() -> str:
    """Short description of the inbound mTLS posture, for logs and /healthz."""
    if not os.getenv("TLS_CERT_FILE") and not os.getenv("TLS_CERT_PEM"):
        return "plain"
    if (
        os.getenv("TLS_CLIENT_CA_FILE")
        or os.getenv("TLS_CLIENT_CA_PEM")
        or os.getenv("TLS_CLIENT_CA_DIR")
    ):
        return "mutual"
    return "server-only"
