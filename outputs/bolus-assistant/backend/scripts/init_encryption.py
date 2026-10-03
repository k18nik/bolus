"""Initialize the local secret without printing it or replacing an existing key."""
import sys,os
from pathlib import Path
from cryptography.fernet import Fernet

path=Path(sys.argv[1])
text=path.read_text()
if any(line.startswith('APP_ENCRYPTION_KEY=') and line.split('=',1)[1].strip() for line in text.splitlines()):
    print('Encryption key already configured.')
else:
    lines=[line for line in text.splitlines() if not line.startswith('APP_ENCRYPTION_KEY=')]
    path.write_text('\n'.join(lines)+'\nAPP_ENCRYPTION_KEY='+Fernet.generate_key().decode()+'\n')
    os.chmod(path,0o600)
    print('Persistent encryption key initialized.')
