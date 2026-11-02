#!/usr/bin/env python3
"""MCP stdio to Velora's authenticated loopback Streamable HTTP endpoint.
Requires Python 3 standard library only. Keep stdout exclusively JSON-RPC.
"""
import json
import os
import sys
import urllib.error
import urllib.request


def serve():
    token = os.environ.get('VELORA_MCP_TOKEN', '')
    port = os.environ.get('VELORA_MCP_PORT', '18427')
    if not token or not port.isdigit() or not 1024 <= int(port) <= 65535:
        print('Configure VELORA_MCP_TOKEN and a valid VELORA_MCP_PORT.', file=sys.stderr)
        return 1
    endpoint = 'http://127.0.0.1:' + port + '/mcp'
    # Never send the local bearer token through an environment proxy or redirect.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    version = '2025-11-25'
    for line in sys.stdin.buffer:
        message = None
        try:
            if len(line) > 1_000_000:
                raise ValueError('Request exceeds 1 MB; use import_file for large documents.')
            message = json.loads(line)
            if not isinstance(message, dict):
                raise ValueError('Expected one JSON-RPC object per line.')
            request = urllib.request.Request(endpoint, data=line.strip(), method='POST', headers={
                'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
                'Accept': 'application/json, text/event-stream', 'MCP-Protocol-Version': version})
            with opener.open(request, timeout=120) as response:
                data = response.read()
            if data:
                result = json.loads(data)
                if message.get('method') == 'initialize':
                    version = result.get('result', {}).get('protocolVersion', version)
                print(json.dumps(result, ensure_ascii=False), flush=True)
        except Exception as error:
            # Do not log payloads, authorization headers, or document content.
            if isinstance(message, dict) and 'id' in message:
                result = {'jsonrpc': '2.0', 'id': message['id'], 'error': {
                    'code': -32000, 'message': 'Velora bridge: ' + str(error)}}
                print(json.dumps(result, ensure_ascii=False), flush=True)
            else:
                print('Velora bridge could not forward a notification.', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(serve())
