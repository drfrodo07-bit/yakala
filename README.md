# Yakala

iPhone için reklam engelleyicili tarayıcı, video yakalama/indirme ve otomatik altyazı uygulaması.

## Özellikler

- **Tarayıcı:** reklam ve açılır pencere engelleme, geri/ileri kaydırma
- **Video yakalama:** sayfada oynayan videoyu (MP4 veya HLS akışı) otomatik algılar
- **Arka planda indirme:** uygulama arka plandayken ve ekran kilitliyken de indirme sürer; HLS akışları otomatik MP4'e çevrilir
- **Oynatıcı:** ortada büyük buton olmayan sade arayüz, ±10/15/30 sn atlama, çift dokunarak sarma, hız seçimi, kaldığın yerden devam
- **Altyazı:** konuşulan dili otomatik algılar (Whisper), istenen dile çevirir (Apple Çeviri), düzenleme, SRT dışa aktarma ve videoya kalıcı gömme. Hepsi telefonun içinde, internete veri gönderilmez.
- Dosyalar, Dosyalar uygulamasında **Yakala** klasöründe de görünür

## iPhone'a kurulum (Windows)

1. Bu repodaki **Releases** bölümünden en son **Yakala.ipa** dosyasını indir.
2. Windows'a Apple'ın sitesinden **iTunes** ve **iCloud** kur (Microsoft Store sürümleri çalışmaz).
3. [Sideloadly](https://sideloadly.io) programını kur ve aç.
4. iPhone'u USB kabloyla bilgisayara bağla, telefonda "Bu bilgisayara güven" de.
5. Yakala.ipa dosyasını Sideloadly penceresine sürükle, Apple ID'ni yaz ve **Start**'a bas.
6. iPhone'da **Ayarlar > Gizlilik ve Güvenlik > Geliştirici Modu**'nu aç (telefon yeniden başlar).
7. **Ayarlar > Genel > VPN ve Cihaz Yönetimi** bölümünden Apple ID'ne güven.

Ücretsiz Apple ID ile kurulan uygulama **7 gün** geçerlidir. Süre dolunca aynı .ipa dosyasını Sideloadly ile tekrar yükle; indirdiğin videolar silinmez.

## Derleme

Her `main` dalına gönderimde GitHub Actions, Mac sunucusunda imzasız `.ipa` derler ve Releases bölümüne ekler. Proje [XcodeGen](https://github.com/yonaskolb/XcodeGen) ile `project.yml` dosyasından oluşturulur.
