# Third-party components

The Android Gradle wrapper (gradlew and gradle-wrapper.jar) is from the Gradle project, distributed under Apache License 2.0: https://github.com/gradle/gradle/blob/master/LICENSE . Build dependencies retain their respective licenses; they are fetched by Gradle.

CoolSync's application code is newly authored. The accessibility focus-acquisition approach was studied in public reference implementations. No ClipRelay application source was copied into this project.

QR code encoding uses fwcd/swift-qrcode-generator (Project Nayuki and fwcd), under the MIT license. Vendored source and license: macos/Sources/VendorQRCode/. QR pixels are rendered by CoolSync without a GPU dependency.

## Sparkle
macOS 업데이트에 Sparkle 2.9.3 (https://github.com/sparkle-project/Sparkle)을 사용합니다. 배포 아카이브의 라이선스를 앱 Resources/Sparkle-LICENSE.txt에 포함합니다. 프레임워크는 공개 GitHub 배포본의 SHA-256을 확인한 뒤 빌드 시 내려받습니다.
