#!/usr/bin/env python3
# Copyright (C) 2021 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This is a chopped down version of record_android_trace from perfetto that
# only opens a trace file in the browser.
# https://github.com/google/perfetto/blob/master/tools/record_android_trace

import http.server
import json
import os
import socketserver
import sys
import webbrowser

try:
  # For Python 3
  from urllib.parse import quote
except ImportError:
  # For Python 2
  from urllib import quote

# HTTP Server used to open the trace in the browser.
class HttpHandler(http.server.SimpleHTTPRequestHandler):
  def end_headers(self):
    self.send_header('Access-Control-Allow-Origin', self.server.allow_origin)
    self.send_header('Cache-Control', 'no-cache')
    super().end_headers()

  def do_GET(self):
    if self.path != '/' + self.server.expected_fname:
      self.send_error(404, "File not found")
      return
    self.server.fname_get_completed = True
    super().do_GET()

  def do_POST(self):
    self.send_error(404, "File not found")

def get_query_string():
  if len(sys.argv) <= 2 or not sys.argv[2] or sys.argv[2].isspace():
    return ""
  with open(sys.argv[2], 'r') as sql:
    text = sql.read()
    if text[0] == '[':
      return "&startupCommands=" + quote(text)
    else:
      return "&query=" + quote(text)

def main():
  open_trace_in_browser(sys.argv[1], True, 'https://ui.perfetto.dev', get_query_string())

def open_trace_in_browser(path, open_browser, origin, query):
  # We reuse the HTTP+RPC port because it's the only one allowed by the CSP.
  PORT = 9001
  path = os.path.abspath(path)
  os.chdir(os.path.dirname(path))
  fname = os.path.basename(path)
  socketserver.TCPServer.allow_reuse_address = True
  with socketserver.TCPServer(('127.0.0.1', PORT), HttpHandler) as httpd:
    address = f'{origin}/#!/?url=http://127.0.0.1:{PORT}/{fname}{query}'
    if open_browser:
      webbrowser.open_new_tab(address)
    else:
      print(f'Open URL in browser: {address}')

    httpd.expected_fname = fname
    httpd.fname_get_completed = None
    httpd.allow_origin = origin
    while httpd.fname_get_completed is None:
      httpd.handle_request()

if __name__ == '__main__':
  sys.exit(main())
