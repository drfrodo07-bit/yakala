# iCatch

iPhone için reklam engelleyicili tarayıcı, video yakalama/indirme ve otomatik altyazı uygulaması.

## Özellikler

- **Safari tarzı tarayıcı:** sekmeler ve özel sekmeler, altta veya üstte adres çubuğu, kaydırınca küçülen çubuklar, başlangıç sayfası (favoriler, sık ziyaret edilenler), adres önerileri, yer imleri ve geçmiş
- **Aloha tarzı menü:** reklam engelleyici (tüm siteler / site bazında), masaüstü sürüm, koyu sayfa, çeviri, okuma modu, sayfada bul, yazı boyutu
- **Video yakalama:** sayfada oynayan videoyu (MP4 veya HLS) yakalar, süresini gösterir, kısa videoları reklam olarak ayırır
- **Tam ekranda Yakala oynatıcısı:** tam ekran düğmesine basınca video, İndir düğmesi olan kendi oynatıcımızda açılır
- **Hızlı indirme:** dosyalar 4 MB'lık parçalara bölünüp aynı anda 8 bağlantıyla iner; akışlar parça parça iner ve MP4'e dönüştürülür; arka planda devam eder
- **Oynatıcı:** ortada büyük buton yok, ±10/15/30 sn atlama, çift dokunarak sarma, hız seçimi, kaldığın yerden devam
- **Altyazı:** konuşulan dili otomatik algılar (Whisper), istenen dile çevirir (Apple Çeviri), düzenleme, SRT ve videoya gömme — hepsi telefonda
- Telefonun açık/koyu görünümüne uyar; dosyalar Dosyalar uygulamasında **iCatch** klasöründe de görünür

## iPhone'a kurulum (Windows)

1. Bu repodaki **Releases** bölümünden en son **iCatch.ipa** dosyasını indir.
2. **3uTools** → Toolbox → **IPA Signature** → Apple ID ile imzala.
3. İmzalı dosyayı 3uTools → Apps → **Install** ile telefona yükle.
4. iPhone'da **Ayarlar > Gizlilik ve Güvenlik > Geliştirici Modu**'nu aç (telefon yeniden başlar).
5. **Ayarlar > Genel > VPN ve Cihaz Yönetimi** bölümünden Apple ID'ne güven.

Ücretsiz Apple ID ile kurulan uygulama **7 gün** geçerlidir. Süre dolunca aynı .ipa dosyasını yeniden imzalayıp yükle; indirdiğin videolar silinmez.

## Derleme

Her `main` dalına gönderimde GitHub Actions, Mac sunucusunda imzasız `.ipa` derler ve Releases bölümüne ekler. Proje [XcodeGen](https://github.com/yonaskolb/XcodeGen) ile `project.yml` dosyasından oluşturulur.
