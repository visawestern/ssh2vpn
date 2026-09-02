# КАТЕГОРИЧЕСКИЙ ЗАПРЕТ — СБОРКА

НИКОГДА. НИ ПРИ КАКИХ ОБСТОЯТЕЛЬСТВАХ. НЕ ИСПОЛЬЗОВАТЬ:
- `CODE_SIGN_IDENTITY="-"`
- `CODE_SIGNING_REQUIRED=NO`
- `CODE_SIGNING_ALLOWED=NO`
- `CODE_SIGN_IDENTITY=""`
- Симуляторы
- Любые варианты сборки без подписи

Это СБРАСЫВАЕТ Apple Developer Team в Xcode.
Пользователь теряет профиль и перезаходит в аккаунт.

## ТОЛЬКО ТАК:

```bash
xcodebuild build -project ... -scheme SSH2VPN -destination 'generic/platform=iOS' -configuration Debug
```

Подпись из проекта. DEVELOPMENT_TEAM = 326TF9BQ3C. Без исключений.
