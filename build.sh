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
# --deep kullanılmaz (Apple önermiyor); pakette gömülü framework/helper yok.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"
# İmzalama sessizce başarısız olabiliyor; doğrulanmadan dağıtıma geçilmez.
codesign --verify --strict "$APP_PATH" || { echo "İMZA DOĞRULAMASI BAŞARISIZ — dağıtım durduruldu"; exit 1; }

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

# Tag, derlenen paketin kendi sürümünden türetilir. Elle yazıldığında MARKETING_VERSION
# ile kaçınılmaz olarak ayrışıyor ve k-deck kurulu sürümü tag ile karşılaştırdığı için
# kullanıcıda "sürekli güncelleme var" durumu oluşuyor.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
TAG="v$APP_VERSION"

if [[ "$1" != "--no-upload" ]]; then
    echo "🚀 GitHub Release oluşturuluyor ve $DMG_NAME yükleniyor ($TAG)..."
    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release upload "$TAG" "$DMG_NAME" --clobber
    else
        gh release create "$TAG" "$DMG_NAME" \
            --title "ZenBar $TAG" \
            --notes "### ✨ ZenBar $TAG Yenilikleri & İyileştirmeler

- **Denetim Merkezi (Control Center) Desteği:** Sağ tık menüsüne eklenen Denetim Merkezi seçeneğiyle macOS 27'de Denetim Merkezi de sistem seviyesinde gizlenebilir veya görünür tutulabilir.
- **Klavye Kısayolları (Hotkey):** Menü çubuğunu doğrudan klavyeden açıp kapatmak için \`⌃⌥⇧Z\` (Ctrl+Opt+Shift+Z) global kısayolu eklendi. İsteğe bağlı olarak menüden \`fn+Z\` kısayolu da açılabilir.
- **Akıllı Tercih Koruması:** Sağ tık menüsünden seçilen uygulamalar ve sistem ikonları artık ayırıcı hareketlerinde veya yeniden başlatmada asla ezilmez.
- **Performans ve Animasyon Akıcılığı:** Menü çubuğu geri yükleme animasyonlarında takılmaları önlemek için bellek rahatlatma zamanlaması optimize edildi.
- **Unified Logging (os_log):** Sistem günlüğü \`os_log\` standardına taşındı; diskte gereksiz dosya büyümesi engellendi.
- **Natif Sistem İkonu Gizleme:** Pil, Wi-Fi, Bluetooth, Ses, Ekran, Ekran Yansıtma, Saat kontrolleri sorunsuz yönetilebilir."
    fi
    echo "🎉 GitHub Release ($TAG) başarıyla yayınlandı!"
fi
