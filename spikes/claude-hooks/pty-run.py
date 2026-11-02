import os, pty, sys, time, select, signal
here=os.path.dirname(os.path.abspath(__file__))
env={k:v for k,v in os.environ.items() if not k.startswith('CMUX')}
env.update(CLAUDE_CONFIG_DIR=os.path.expanduser('~/.claude-work'),MEUM_TAB='pty',MEUM_SOCK=here+'/run/meum.sock',TERM='xterm-256color')
pid,fd=pty.fork()
if pid==0:
    os.chdir('/Users/dev/code/codex-spaces/home')
    os.execve('/opt/homebrew/bin/claude',['claude','--model','haiku','--permission-mode','default','--settings',here+'/settings.spike.json',
      'Use the Bash tool to run exactly: touch '+here+'/run/pty-touch.txt'],env)
open(here+'/run/pty.pid','w').write(str(pid))
buf=b''; t0=time.time(); sent=0
while time.time()-t0<float(sys.argv[1]):
    r,_,_=select.select([fd],[],[],0.5)
    if r:
        try: d=os.read(fd,65536)
        except OSError: break
        buf+=d
    pass
open(here+'/run/pty-screen.txt','wb').write(buf[-6000:])
os.kill(pid,signal.SIGTERM); time.sleep(1)
try: os.kill(pid,signal.SIGKILL)
except ProcessLookupError: pass
