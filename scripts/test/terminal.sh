notty() { # notty <command…>: run the command with no controlling terminal (as an agent's shell)
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" </dev/null
}
typed() { # typed <answer> <command…>: run the command on a new pseudo-terminal and type <answer>
  python3 - "$@" <<'PY'
import os, pty, sys
answer, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
os.write(fd, (answer + "\n").encode())
out = b""
while True:
    try:
        d = os.read(fd, 1024)
    except OSError:
        break
    if not d:
        break
    out += d
sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
PY
}
