#!/bin/zsh
# 生成一个仅供本机使用的自签名代码签名证书，存放在项目内独立的钥匙串里（不动登录钥匙串）。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .signing && cd .signing
cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = MenuBasket Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:menubasket -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:menubasket
security create-keychain -p menubasket "$PWD/menubasket.keychain-db"
security unlock-keychain -p menubasket "$PWD/menubasket.keychain-db"
security import id.p12 -k "$PWD/menubasket.keychain-db" -P menubasket -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k menubasket "$PWD/menubasket.keychain-db" >/dev/null
rm -f key.pem id.p12
echo "签名证书已生成"
