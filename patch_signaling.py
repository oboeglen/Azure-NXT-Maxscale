#!/usr/bin/env python3
"""Apply LookupSessionId retry patch to grpc/server.go"""
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

old = '''func (s *Server) LookupSessionId(ctx context.Context, request *LookupSessionIdRequest) (*LookupSessionIdReply, error) {
\tstatsGrpcServerCalls.WithLabelValues("LookupSessionId").Inc()
\t// TODO: Remove debug logging
\ts.logger.Printf("Lookup session id for room session id %s", request.RoomSessionId)
\tsid, err := s.hub.GetSessionIdByRoomSessionId(api.RoomSessionId(request.RoomSessionId))
\tif errors.Is(err, ErrNoSuchRoomSession) {
\t\treturn nil, status.Error(codes.NotFound, "no such room session id")
\t} else if err != nil {
\t\treturn nil, err
\t}

\tif sid != "" && request.DisconnectReason != "" {
\t\ts.hub.DisconnectSessionByRoomSessionId(sid, api.RoomSessionId(request.RoomSessionId), request.DisconnectReason)
\t}
\treturn &LookupSessionIdReply{
\t\tSessionId: string(sid),
\t}, nil
}'''

new = '''func (s *Server) LookupSessionId(ctx context.Context, request *LookupSessionIdRequest) (*LookupSessionIdReply, error) {
\tstatsGrpcServerCalls.WithLabelValues("LookupSessionId").Inc()
\ts.logger.Printf("Lookup session id for room session id %s", request.RoomSessionId)
\t// Retry to handle race condition: session being registered concurrently
\t// returns "unknown room session id" before SetRoomSession completes.
\t// See: https://github.com/strukturag/nextcloud-spreed-signaling/issues/1261
\tconst maxRetries = 10
\tconst retryInterval = 50 * time.Millisecond
\tvar sid api.PublicSessionId
\tvar err error
\tfor i := 0; i < maxRetries; i++ {
\t\tsid, err = s.hub.GetSessionIdByRoomSessionId(api.RoomSessionId(request.RoomSessionId))
\t\tif err == nil {
\t\t\tbreak
\t\t}
\t\tif i < maxRetries-1 {
\t\t\tselect {
\t\t\tcase <-ctx.Done():
\t\t\t\treturn nil, status.Error(codes.Canceled, "context canceled")
\t\t\tcase <-time.After(retryInterval):
\t\t\t}
\t\t}
\t}
\tif err != nil {
\t\treturn nil, status.Error(codes.NotFound, "no such room session id")
\t}
\tif sid != "" && request.DisconnectReason != "" {
\t\ts.hub.DisconnectSessionByRoomSessionId(sid, api.RoomSessionId(request.RoomSessionId), request.DisconnectReason)
\t}
\treturn &LookupSessionIdReply{
\t\tSessionId: string(sid),
\t}, nil
}'''

assert old in content, "Pattern not found in server.go — upstream may have changed"
content = content.replace(old, new)
content = content.replace('\t"errors"\n', '')
if '"time"' not in content:
    content = content.replace('\t"net/url"', '\t"net/url"\n\t"time"')

with open(path, 'w') as f:
    f.write(content)
print(f"Patch applied to {path}")
