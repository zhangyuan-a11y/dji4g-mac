#!/bin/sh
# 造一张本地自签的代码签名证书，给 DJI4G.app 用。
#
# 为什么需要它：系统按「签名身份」记授权。临时签名（codesign --sign -）的身份
# 是那份二进制的 cdhash，编译一次换一个，所以每装一次新版本，客户之前点过的
# 麦克风授权就作废，而系统的授权框一辈子只弹一次 —— 结果是「昨天还能打电话，
# 今天没声音了」。换成固定证书之后身份变成证书本身，证书不变，授权就一直
# 在，装多少遍都不用再点。
#
# 证书是自签的，不进系统信任库，也不用来对外证明身份，它只回答系统一个问题：
# 「这还是不是同一个 App」。私钥存在一个独立钥匙串里，密码是 dji4g —— 本地
# 自用，不是机密。
#
# 只用跑一次。跑完之后 scripts/make-app.sh 会自动发现它。
set -e
cd "$(dirname "$0")/.."

NAME="DJI4G Local Signing"
WORK="${TMPDIR:-/tmp}/dji4g-signing"
KC="${HOME}/Library/Keychains/dji4g-signing.keychain-db"

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
    echo "证书已经在了，不用重做：$KC"
    exit 0
fi

mkdir -p "$WORK"
cat > "$WORK/cs.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = DJI4G Local Signing
O = DJI4G
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes -config "$WORK/cs.cnf" >/dev/null 2>&1

# -legacy：新版 openssl 默认那套加密 macOS 的 Security 框架读不了，会报
# 「MAC verification failed during PKCS12 import」。
openssl pkcs12 -export -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:dji4g -name "$NAME" -legacy >/dev/null 2>&1

security create-keychain -p dji4g "$KC" 2>/dev/null || true
security set-keychain-settings -lut 21600 "$KC" 2>/dev/null || true
security unlock-keychain -p dji4g "$KC"
security import "$WORK/id.p12" -k "$KC" -P dji4g -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k dji4g "$KC" >/dev/null 2>&1

# 只把这张证书的钥匙串挂到搜索列表上，login 那把原位不动。
security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "$KC"

echo "证书造好了：$NAME"
echo "私钥备份留在：$WORK（重装系统前记得留一份）"
