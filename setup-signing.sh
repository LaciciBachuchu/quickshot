#!/bin/zsh
# 在登录钥匙串里生成一张本机专用的代码签名证书「QuickShot Local Signing」（只需运行一次）
# 用固定证书签名后，App 的签名身份不会因为重新编译而改变，屏幕录制权限授权一次就一直有效
# （默认的临时签名每次编译都会变，系统会当成新 App，要求重新授权）
set -e
NAME="QuickShot Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "已存在：$NAME"
    exit 0
fi
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cat > "$W/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$W/key.pem" -out "$W/cert.pem" -days 3650 -config "$W/cert.cnf" 2>/dev/null
PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$W/key.pem" -in "$W/cert.pem" -name "$NAME" -out "$W/id.p12" -passout "pass:$PASS"
security import "$W/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "已创建：$NAME（之后 ./build.sh 会自动用它签名）"
