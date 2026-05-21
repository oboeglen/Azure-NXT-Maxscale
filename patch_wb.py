import shutil, sys

filepath = '/var/www/html/apps/whiteboard/lib/Service/WhiteboardContentService.php'

with open(filepath, 'r') as f:
    content = f.read()

old = (
    '\tpublic function getContent(File $file): array {\n'
    '\t\t$fileContent = $file->getContent();\n'
    "\t\tif ($fileContent === '') {\n"
    "\t\t\t$fileContent = '{\"elements\":[],\"scrollToContent\":true}';\n"
    '\t\t}\n'
    '\n'
    '\t\treturn json_decode($fileContent, true, 512, JSON_THROW_ON_ERROR);\n'
    '\t}'
)

new = (
    '\tpublic function getContent(File $file): array {\n'
    '\t\t$fileContent = $file->getContent();\n'
    "\t\tif ($fileContent === '' || trim($fileContent) === '') {\n"
    "\t\t\t$fileContent = '{\"elements\":[],\"scrollToContent\":true}';\n"
    '\t\t}\n'
    '\n'
    '\t\ttry {\n'
    '\t\t\treturn json_decode($fileContent, true, 512, JSON_THROW_ON_ERROR);\n'
    '\t\t} catch (\\JsonException $e) {\n'
    "\t\t\t// Contenu invalide (ex: 1 octet MinIO) — retour a l'etat vide\n"
    "\t\t\treturn ['elements' => [], 'files' => [], 'scrollToContent' => true];\n"
    '\t\t}\n'
    '\t}'
)

if old in content:
    shutil.copy(filepath, filepath + '.bak')
    content = content.replace(old, new)
    with open(filepath, 'w') as f:
        f.write(content)
    print('PATCH OK')
else:
    print('PATTERN NOT FOUND — checking content snippet:')
    idx = content.find('public function getContent')
    print(repr(content[idx:idx+300]))
    sys.exit(1)
