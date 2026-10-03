from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import os, json

root=Path(__file__).resolve().parents[1]
project=root/'outputs/bolus-assistant'
ignored={'node_modules','.next','.build','.git','.swiftpm','.venv','__pycache__','.pytest_cache','.hypothesis','htmlcov','report_files','xcuserdata','build'}
def files(base):
    for folder, dirs, names in os.walk(base):
        dirs[:]=[d for d in dirs if d not in ignored]
        for name in sorted(names):
            path=Path(folder)/name
            if name in {'.DS_Store','.coverage','coverage.xml'}:continue
            if name.startswith('.env') and name!='.env.example':continue
            if path.suffix in {'.db','.sqlite','.sqlite3','.pyc','.tsbuildinfo','.log'}:continue
            if path.is_symlink():continue
            yield path

source=root/'outputs/bolus-assistant-source.zip'
with ZipFile(source,'w',ZIP_DEFLATED,compresslevel=9) as archive:
    for path in files(project):archive.write(path,Path('bolus-assistant')/path.relative_to(project))

iphone=root/'outputs/Bolus-iPhone.zip'
archive_root=root/'work/Bolus.xcarchive'
assert (archive_root/'Products/Applications/Bolus.app/Bolus').exists()
with ZipFile(iphone,'w',ZIP_DEFLATED,compresslevel=9) as archive:
    for path in files(project/'ios'):archive.write(path,Path('Bolus-iPhone/ios')/path.relative_to(project/'ios'))
    for path in files(archive_root):archive.write(path,Path('Bolus-iPhone/UnsignedArchive/Bolus.xcarchive')/path.relative_to(archive_root))
    archive.writestr('Bolus-iPhone/НАЧНИТЕ ЗДЕСЬ.md','''# Bolus для iPhone

1. Откройте `ios/Bolus.xcodeproj` на Mac с Xcode.
2. В Signing & Capabilities выберите свою Apple Team, подключите iPhone и нажмите Run.
3. В приложении задайте доступный телефону адрес вашего сервера и войдите в свой дневник.

Подробные шаги, HealthKit и требования к адресу: `ios/README.md`.

`UnsignedArchive/Bolus.xcarchive` — собранный Release arm64 архив без подписи. Это не устанавливаемая IPA. Подписать и экспортировать можно своей Apple Team через Xcode. Публикация в TestFlight не выполнялась.

Приложению нужен работающий сервер из отдельного `bolus-assistant-source.zip`. На физическом iPhone localhost означает сам телефон. Для постоянной работы используйте доступный HTTPS-адрес. На этом Mac сервер уже работает по http://localhost:8080.

В архиве нет API-ключей, паролей или данных дневника. Они остаются на вашем сервере. Новая установка полного проекта не содержит ваших существующих данных.

Проверено: сборки Simulator и iPhone arm64, три Swift-теста, запуск в Simulator. Чтение реальных HealthKit-данных и установка на физический iPhone требуют вашей подписи и разрешений на устройстве.
''')

# Check exact local infrastructure secrets without printing their values.
secrets=[]
for line in (project/'.env').read_text().splitlines():
    name,sep,value=line.partition('=')
    if sep and name in {'POSTGRES_PASSWORD','APP_ENCRYPTION_KEY'}:
        value=value.strip().strip('"').strip("'")
        if len(value)>12:secrets.append(value.encode())
for path in (source,iphone):
    with ZipFile(path) as archive:
        assert archive.testzip() is None
        for name in archive.namelist():
            assert not name.endswith('/.env') and 'node_modules/' not in name and '/.build/' not in name
            data=archive.read(name)
            assert not any(secret in data for secret in secrets), 'Local secret found in package'
        print(json.dumps({'package':path.name,'files':len(archive.namelist()),'bytes':path.stat().st_size,'integrity':'ok','local_secrets':'excluded'}))
