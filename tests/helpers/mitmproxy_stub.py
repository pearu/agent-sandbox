"""A stand-in for the `mitmproxy` package so components/allowlist_addon.py can
be unit-tested without mitmproxy installed. Only what the addon imports."""


class Response:
    def __init__(self, status_code, content, headers):
        self.status_code = status_code
        self.content = content
        self.headers = headers
        self.stream = False

    @staticmethod
    def make(status_code, content=b"", headers=None):
        return Response(status_code, content, headers or {})


class HTTPFlow:  # only used as a type annotation by the addon
    pass
