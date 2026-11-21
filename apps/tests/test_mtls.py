"""Tests for the mutual-TLS layer: real handshakes, not mocks.

The point of these tests is to fail if someone "fixes" the listener by relaxing
CERT_REQUIRED, or if a certificate loses the SAN/hostname checking the gateway
depends on. A unit test that only asserts a config dict would not catch either.
"""

from __future__ import annotations

import http.client
import socket
import ssl
import threading
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
import uvicorn
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
from fastapi import FastAPI
from fastapi.testclient import TestClient

from common import db, tls
from common.ops import make_ops_app

TLS_ENV = (
    "TLS_CERT_FILE",
    "TLS_KEY_FILE",
    "TLS_CLIENT_CA_FILE",
    "TLS_CERT_PEM",
    "TLS_KEY_PEM",
    "TLS_CLIENT_CA_PEM",
    "TLS_CLIENT_CA_DIR",
    "TLS_CA_FILE",
    "TLS_CA_PEM",
    "TLS_CLIENT_CERT_FILE",
    "TLS_CLIENT_KEY_FILE",
    "TLS_CLIENT_CERT_PEM",
    "TLS_CLIENT_KEY_PEM",
    "TLS_REQUIRE_CLIENT_CERT",
)


def _new_key() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _key_pem(key: rsa.RSAPrivateKey) -> bytes:
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )


def _cert_pem(cert: x509.Certificate) -> bytes:
    return cert.public_bytes(serialization.Encoding.PEM)


def _ca() -> tuple[rsa.RSAPrivateKey, x509.Certificate]:
    key = _new_key()
    now = datetime.now(UTC)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test-ca")])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(hours=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=False,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(key, hashes.SHA256())
    )
    return key, cert


def _leaf(
    ca_key: rsa.RSAPrivateKey,
    ca_cert: x509.Certificate,
    *,
    common_name: str,
    usage: x509.ObjectIdentifier,
    dns_names: list[str] | None = None,
) -> tuple[rsa.RSAPrivateKey, x509.Certificate]:
    key = _new_key()
    now = datetime.now(UTC)
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)]))
        .issuer_name(ca_cert.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(hours=1))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.ExtendedKeyUsage([usage]),
            critical=False,
        )
    )
    if dns_names:
        builder = builder.add_extension(
            x509.SubjectAlternativeName(
                [x509.DNSName(name) for name in dns_names]
                + [x509.IPAddress(__import__("ipaddress").ip_address("127.0.0.1"))]
            ),
            critical=False,
        )
    return key, builder.sign(ca_key, hashes.SHA256())


@pytest.fixture()
def pki(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> dict[str, str]:
    """Write a throwaway CA, server leaf and client leaf to disk."""
    for name in TLS_ENV:
        monkeypatch.delenv(name, raising=False)

    ca_key, ca_cert = _ca()
    server_key, server_cert = _leaf(
        ca_key,
        ca_cert,
        common_name="auth",
        usage=ExtendedKeyUsageOID.SERVER_AUTH,
        dns_names=["localhost", "auth"],
    )
    client_key, client_cert = _leaf(
        ca_key,
        ca_cert,
        common_name="gateway",
        usage=ExtendedKeyUsageOID.CLIENT_AUTH,
    )

    # A second, independent caller CA: it issues a perfectly valid client certificate that
    # no server is configured to trust. This is the "new service has no allow rule" case.
    other_ca_key, other_ca_cert = _ca()
    other_client_key, other_client_cert = _leaf(
        other_ca_key,
        other_ca_cert,
        common_name="unlisted-client",
        usage=ExtendedKeyUsageOID.CLIENT_AUTH,
    )

    paths = {
        "ca": tmp_path / "ca.crt",
        "server_cert": tmp_path / "server.crt",
        "server_key": tmp_path / "server.key",
        "client_cert": tmp_path / "client.crt",
        "client_key": tmp_path / "client.key",
        "other_ca": tmp_path / "other-ca.crt",
        "other_client_cert": tmp_path / "other-client.crt",
        "other_client_key": tmp_path / "other-client.key",
    }
    paths["ca"].write_bytes(_cert_pem(ca_cert))
    paths["server_cert"].write_bytes(_cert_pem(server_cert))
    paths["server_key"].write_bytes(_key_pem(server_key))
    paths["client_cert"].write_bytes(_cert_pem(client_cert))
    paths["client_key"].write_bytes(_key_pem(client_key))
    paths["other_ca"].write_bytes(_cert_pem(other_ca_cert))
    paths["other_client_cert"].write_bytes(_cert_pem(other_client_cert))
    paths["other_client_key"].write_bytes(_key_pem(other_client_key))
    return {name: str(path) for name, path in paths.items()}


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _start_server(
    app: FastAPI, **ssl_kwargs: object
) -> tuple[uvicorn.Server, int, threading.Thread]:
    port = _free_port()
    server = uvicorn.Server(
        uvicorn.Config(
            app,
            host="127.0.0.1",
            port=port,
            log_config=None,
            access_log=False,
            **ssl_kwargs,
        )
    )
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        if time.monotonic() > deadline:  # pragma: no cover - environment problem
            raise RuntimeError("test TLS server did not start")
        time.sleep(0.02)
    return server, port, thread


def _stop_server(server: uvicorn.Server, thread: threading.Thread) -> None:
    server.should_exit = True
    thread.join(timeout=10)


def _plain_app() -> FastAPI:
    app = FastAPI()

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app


def test_server_kwargs_require_client_certificate(
    pki: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("TLS_CERT_FILE", pki["server_cert"])
    monkeypatch.setenv("TLS_KEY_FILE", pki["server_key"])
    monkeypatch.setenv("TLS_CLIENT_CA_FILE", pki["ca"])

    kwargs = tls.server_ssl_kwargs()

    assert kwargs is not None
    assert kwargs["ssl_cert_reqs"] == ssl.CERT_REQUIRED
    assert kwargs["ssl_ca_certs"] == pki["ca"]


def test_server_kwargs_absent_without_certificates(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in TLS_ENV:
        monkeypatch.delenv(name, raising=False)
    assert tls.server_ssl_kwargs() is None


def test_inline_pem_is_materialised_to_a_private_file(
    pki: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("TLS_CERT_PEM", Path(pki["server_cert"]).read_text())
    monkeypatch.setenv("TLS_KEY_PEM", Path(pki["server_key"]).read_text())
    monkeypatch.setenv("TLS_CLIENT_CA_PEM", Path(pki["ca"]).read_text())

    kwargs = tls.server_ssl_kwargs()

    assert kwargs is not None
    cert_path = Path(str(kwargs["ssl_certfile"]))
    assert cert_path.is_file()
    assert cert_path.stat().st_mode & 0o077 == 0  # 0600: not readable by group/other
    assert "BEGIN CERTIFICATE" in cert_path.read_text()


def test_handshake_without_client_certificate_is_rejected(
    pki: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("TLS_CERT_FILE", pki["server_cert"])
    monkeypatch.setenv("TLS_KEY_FILE", pki["server_key"])
    monkeypatch.setenv("TLS_CLIENT_CA_FILE", pki["ca"])

    server, port, thread = _start_server(_plain_app(), **(tls.server_ssl_kwargs() or {}))
    try:
        context = ssl.create_default_context(cafile=pki["ca"])
        with pytest.raises((ssl.SSLError, ConnectionError, OSError)):
            conn = http.client.HTTPSConnection("localhost", port, timeout=5, context=context)
            conn.request("GET", "/healthz")
            conn.getresponse()
    finally:
        _stop_server(server, thread)


def test_handshake_with_client_certificate_succeeds(
    pki: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("TLS_CERT_FILE", pki["server_cert"])
    monkeypatch.setenv("TLS_KEY_FILE", pki["server_key"])
    monkeypatch.setenv("TLS_CLIENT_CA_FILE", pki["ca"])

    server, port, thread = _start_server(_plain_app(), **(tls.server_ssl_kwargs() or {}))
    try:
        context = ssl.create_default_context(cafile=pki["ca"])
        context.load_cert_chain(pki["client_cert"], pki["client_key"])
        conn = http.client.HTTPSConnection("localhost", port, timeout=5, context=context)
        conn.request("GET", "/healthz")
        response = conn.getresponse()
        assert response.status == 200
        assert response.read() == b'{"status":"ok"}'
    finally:
        _stop_server(server, thread)


def test_client_context_verifies_and_presents(
    pki: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("TLS_CA_FILE", pki["ca"])
    monkeypatch.setenv("TLS_CLIENT_CERT_FILE", pki["client_cert"])
    monkeypatch.setenv("TLS_CLIENT_KEY_FILE", pki["client_key"])

    context = tls.client_ssl_context()

    assert context is not None
    assert context.verify_mode == ssl.CERT_REQUIRED
    assert context.check_hostname is True


def test_client_context_is_absent_without_a_ca(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in TLS_ENV:
        monkeypatch.delenv(name, raising=False)
    assert tls.client_ssl_context() is None


def test_ops_app_is_health_only(monkeypatch: pytest.MonkeyPatch) -> None:
    """Liveness never depends on the database; readiness degrades to 503, not a crash."""
    client = TestClient(make_ops_app("auth"))

    assert client.get("/healthz").json() == {"status": "ok", "service": "auth"}

    # Other tests in this process initialise the engine at import time, so patch the
    # probe itself rather than relying on suite ordering.
    def _database_down() -> None:
        raise RuntimeError("database unreachable")

    monkeypatch.setattr(db, "ping", _database_down)
    ready = client.get("/readyz")
    assert ready.status_code == 503
    assert ready.json()["status"] == "not-ready"

    monkeypatch.setattr(db, "ping", lambda: None)
    assert client.get("/readyz").json() == {"status": "ready", "service": "auth"}

    # The ops port must not expose business endpoints.
    assert client.get("/auth/login").status_code == 404
    assert client.get("/catalog/items").status_code == 404


def test_client_ca_directory_bundles_every_allowed_issuer(
    pki: dict[str, str], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """TLS_CLIENT_CA_DIR: each allowed caller identity contributes one CA file.

    This is the shape Kubernetes uses -- a projected volume, one file per caller -- so the
    bundle the server verifies against is exactly the set of callers someone allowed.
    """
    clients = tmp_path / "clients"
    clients.mkdir()
    (clients / "gateway-ca.crt").write_bytes(Path(pki["ca"]).read_bytes())

    monkeypatch.setenv("TLS_CERT_FILE", pki["server_cert"])
    monkeypatch.setenv("TLS_KEY_FILE", pki["server_key"])
    monkeypatch.setenv("TLS_CLIENT_CA_DIR", str(clients))

    kwargs = tls.server_ssl_kwargs()
    assert kwargs is not None
    assert kwargs["ssl_cert_reqs"] == ssl.CERT_REQUIRED
    bundle = Path(str(kwargs["ssl_ca_certs"]))
    assert bundle.read_text().count("BEGIN CERTIFICATE") == 1

    server, port, thread = _start_server(_plain_app(), **kwargs)
    try:
        context = ssl.create_default_context(cafile=pki["ca"])
        context.load_cert_chain(pki["client_cert"], pki["client_key"])
        conn = http.client.HTTPSConnection("localhost", port, timeout=5, context=context)
        conn.request("GET", "/healthz")
        assert conn.getresponse().status == 200
    finally:
        _stop_server(server, thread)


def test_valid_certificate_from_an_unlisted_issuer_is_refused(
    pki: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    """Issuance is not authorisation: a new caller needs an explicit allow rule.

    The certificate below is well-formed, has the right EKU and chains to a real CA. It is
    still refused, because its issuer is not in the bundle this server trusts -- which is
    what stops "we issued them a certificate" from meaning "they can call everything".
    """
    monkeypatch.setenv("TLS_CERT_FILE", pki["server_cert"])
    monkeypatch.setenv("TLS_KEY_FILE", pki["server_key"])
    monkeypatch.setenv("TLS_CLIENT_CA_FILE", pki["ca"])

    server, port, thread = _start_server(_plain_app(), **(tls.server_ssl_kwargs() or {}))
    try:
        context = ssl.create_default_context(cafile=pki["ca"])
        context.load_cert_chain(pki["other_client_cert"], pki["other_client_key"])
        with pytest.raises((ssl.SSLError, ConnectionError, OSError)):
            conn = http.client.HTTPSConnection("localhost", port, timeout=5, context=context)
            conn.request("GET", "/healthz")
            conn.getresponse()
    finally:
        _stop_server(server, thread)


def test_empty_client_ca_directory_fails_loudly(
    pki: dict[str, str], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A trust directory with no CAs is a misconfiguration, not "trust nothing" silently."""
    empty = tmp_path / "empty"
    empty.mkdir()
    monkeypatch.setenv("TLS_CERT_FILE", pki["server_cert"])
    monkeypatch.setenv("TLS_KEY_FILE", pki["server_key"])
    monkeypatch.setenv("TLS_CLIENT_CA_DIR", str(empty))

    with pytest.raises(ValueError):
        tls.server_ssl_kwargs()
