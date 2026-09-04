# -*- coding: utf-8 -*-
"""build/web 的本機預覽伺服器。

原本直接用 `python -m http.server`，但它在 Windows 上會被連線中斷打死：
瀏覽器在字型／canvaskit 這種大檔傳到一半換頁或重整，socket 就斷了，
ConnectionAbortedError 一路往上拋，整個行程收掉，畫面就再也開不起來。
這裡把那三種「對方先掛」的例外吃掉（本來就不是錯），其餘照舊。
"""
import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class Handler(SimpleHTTPRequestHandler):
    # canvaskit 的 wasm 要正確的 MIME 才會走串流編譯
    extensions_map = {
        **SimpleHTTPRequestHandler.extensions_map,
        '.wasm': 'application/wasm',
        '.js': 'text/javascript',
        '.json': 'application/json',
    }

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
            # 對方斷線不是伺服器的錯，關掉這條連線就好
            self.close_connection = True

    def log_message(self, fmt, *args):
        # 只印錯誤；每個資源都印一行的話，光載入就幾百行
        code = args[1] if len(args) > 1 else ''
        if str(code).startswith(('4', '5')):
            sys.stderr.write('%s %s\n' % (self.path, code))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    root = sys.argv[2] if len(sys.argv) > 2 else 'build/web'
    os.chdir(root)
    srv = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    srv.daemon_threads = True
    print('serving %s on http://127.0.0.1:%d' % (os.getcwd(), port), flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    main()
