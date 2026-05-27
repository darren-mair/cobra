$ErrorActionPreference = "Stop"

hugo `
    --config hugo.toml,hugo.production.toml `
    --environment production
