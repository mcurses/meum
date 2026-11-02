import socket, os, sys, time, json
p=sys.argv[1]; log=sys.argv[2]
if os.path.exists(p): os.unlink(p)
s=socket.socket(socket.AF_UNIX); s.bind(p); s.listen(16)
while True:
    c,_=s.accept(); d=b''
    while True:
        b=c.recv(65536)
        if not b: break
        d+=b
    with open(log,'a') as f: f.write(d.decode().strip()+'\n')
    c.close()
