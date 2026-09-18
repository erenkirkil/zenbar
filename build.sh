#!/bin/bash
set -e

# Ayarlar
IDENTITY="Developer ID Application: EREN KIRKIL (992XYS9346)"
NOTARY_PROFILE="zenbar-notary"
APP_NAME="ZenBar"
DMG_NAME="ZenBar.dmg"
PROJECT_DIR=$(pwd)
BUILD_DIR="$PROJECT_DIR/build/Release"

echo "🧹 Önceki derlemeler temizleniyor..."
rm -rf "$PROJECT_DIR/build"
rm -f "$DMG_NAME"

echo "🔨 Uygulama derleniyor..."
xcodebuild -scheme $APP_NAME -configuration Release clean build SYMROOT="$PROJECT_DIR/build"

APP_PATH="$BUILD_DIR/$APP_NAME.app"

echo "🔐 Uygulama (.app) imzalanıyor..."
codesign --deep --force --options runtime --sign "$IDENTITY" "$APP_PATH"

echo "📦 DMG dosyası oluşturuluyor..."
mkdir -p "$PROJECT_DIR/build/dmg_staging"
cp -R "$APP_PATH" "$PROJECT_DIR/build/dmg_staging/"
ln -s /Applications "$PROJECT_DIR/build/dmg_staging/Applications"
hdiutil create -volname $APP_NAME -srcfolder "$PROJECT_DIR/build/dmg_staging" -ov -format UDZO "$DMG_NAME"

echo "🔐 DMG dosyası imzalanıyor..."
codesign --force --sign "$IDENTITY" "$DMG_NAME"

echo "🚀 DMG Notarization (Onaylama) için Apple'a gönderiliyor (Bu işlem birkaç dakika sürebilir)..."
xcrun notarytool submit "$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait

echo "📎 Onay bileti DMG dosyasına zımbalanıyor (Stapling)..."
xcrun stapler staple "$DMG_NAME"

echo "✅ Tebrikler! $DMG_NAME dosyası başarıyla imzalandı, onaylandı ve dağıtıma hazır hale getirildi."

TAG="v1.1.0"

if [[ "$1" != "--no-upload" ]]; then
    echo "🚀 GitHub Release oluşturuluyor ve $DMG_NAME yükleniyor ($TAG)..."
    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release upload "$TAG" "$DMG_NAME" --clobber
    else
        gh release create "$TAG" "$DMG_NAME" \
            --title "ZenBar $TAG" \
            --notes "### ✨ macOS 27 Native Menu Bar Support & Swift 6

- **MenuBarClientCore Entegrasyonu:** macOS 27 için yerel private framework mimarisi ile sıfır yapay pencere/çizgi kalıntısıyla natif gizleme.
- **Swift 6 & Concurrency Güvenliği:** Arka plan tamamlama kuyrukları MainActor ile tam uyumlu hale getirildi.
- **AppKit SF Symbol Uyumluluğu:** Dinamik açık/koyu menü çubuğu temasıyla tam uyumlu template ikonlar.
- **Akıllı Algılama:** MenuBarAgent altındaki uygulamaları otomatik algılama ve sağ tık menüsü ile yönetebilme."
    fi
    echo "🎉 GitHub Release ($TAG) başarıyla yayınlandı!"
fi
