```
fly auth login
fly apps create vaultwarden
cat .env | fly secrets import
fly volumes create app_data --size 1
fly deploy
fly ssh console
```

https://github.com/dani-garcia/vaultwarden
