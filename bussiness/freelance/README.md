# Freelance/Affiliate Business Architecture

## Files
- `freelance-architecture.png` — полная ArchiMate диаграмма (все слои)
- `freelance-architecture.puml` — PlantUML исходник (редактируемый)
- `freelance-architecture.svg` — векторная версия
- `infra-layout.png` — схема инфраструктуры (технологический слой)
- `business-flow.png` — бизнес-процессы и сервисы

## Infrastructure Summary

```
Cloudflare (DNS + защита)
├── yourdomain.com        → GitHub Pages (портфолио)
├── crm.yourdomain.com    → HubSpot / Notion
├── tracker.yourdomain.com→ VPS #1: Keitaro
└── go.yourdomain.com     → VPS #2: Лендинги

Email: Google Workspace (hello@) + Brevo (рассылки)
Backups: Backblaze B2
Passwords: Bitwarden
```

## Monthly Budget: $20-30
