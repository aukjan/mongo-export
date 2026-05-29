# atlas-export

Bulk-export all collections from a MongoDB Atlas cluster as compressed JSON.

- Exports every collection as line-delimited JSON
- Splits large files automatically (configurable threshold)
- Produces a zip archive with a clean hierarchy: `Project / Cluster / Database / Collection`
- Supports `.env` file for connection settings
- Filter databases by name (substring match)

## Requirements

- [mongosh](https://www.mongodb.com/docs/mongodb-shell/install/)
- [mongoexport](https://www.mongodb.com/docs/database-tools/mongoexport/) (part of MongoDB Database Tools)
- `zip`
- `split` (included with macOS/Linux)

## Installation

```bash
git clone https://github.com/aukjan/mongo-export.git
cd mongo-export
chmod +x atlas-export.sh
```

## Quick Start

1. Create a `.env` file:

```bash
ATLAS_HOST=cluster0.abc123.mongodb.net
ATLAS_USERNAME=admin
ATLAS_PASSWORD=s3cret
ATLAS_PROJECT=MyProject
ATLAS_CLUSTER=Production
```

2. Run the export:

```bash
./atlas-export.sh
```

That's it. The script reads `.env` automatically and produces a timestamped zip file.

## Usage

```
Usage: atlas-export.sh [OPTIONS]

REQUIRED (via CLI flags or .env file)
  --host <host>             Atlas cluster host (e.g. cluster0.abc123.mongodb.net)
  --username <user>         MongoDB username
  --password <pass>         MongoDB password
  --project <name>          Atlas project name  (top-level folder in the archive)
  --cluster <name>          Atlas cluster name   (second-level folder)

OPTIONAL
  --env-file <path>         Path to .env file               (default: .env in cwd)
  --no-env                  Skip loading .env file
  --filter <substring>      Only export databases whose name contains <substring>
                            (case-insensitive)
  --output-dir <dir>        Base output directory           (default: ./atlas-export)
  --max-file-size <size>    Split threshold per file        (default: 500M)
                            Accepts K/KB, M/MB, G/GB
  --backup-name <name>      Prefix for the zip file name    (default: none)
  --keep-raw                Keep uncompressed files after zipping
  --help                    Show help message
```

## Examples

```bash
# Export everything
./atlas-export.sh \
  --host cluster0.abc123.mongodb.net \
  --username admin --password 's3cret' \
  --project MyProject --cluster Production

# Export only databases matching a pattern
./atlas-export.sh --filter "accounts_payable_"

# Custom split threshold (100 MB) and output directory
./atlas-export.sh --max-file-size 100M --output-dir ./backups

# Add a prefix to the zip filename
./atlas-export.sh --backup-name daily
# → daily_MyProject_Production_20260529_143022.zip

# Use a different env file
./atlas-export.sh --env-file .env.production

# Skip .env entirely
./atlas-export.sh --no-env --host cluster0.abc123.mongodb.net ...
```

## .env File

The script loads `.env` from the current directory by default. CLI flags always override `.env` values.

| Variable | Description |
|----------|-------------|
| `ATLAS_HOST` | Cluster host |
| `ATLAS_USERNAME` | MongoDB username |
| `ATLAS_PASSWORD` | MongoDB password |
| `ATLAS_PROJECT` | Project name |
| `ATLAS_CLUSTER` | Cluster name |
| `ATLAS_FILTER` | Database name filter (substring) |
| `ATLAS_OUTPUT_DIR` | Output directory |
| `ATLAS_BACKUP_NAME` | Prefix for the zip file name |
| `ATLAS_MAX_FILE_SIZE` | Split threshold (e.g. `500M`) |

## Output Structure

```
atlas-export/
├── MyProject_Production_20260529_143022.zip
└── MyProject/              (only with --keep-raw)
    └── Production/
        ├── database_one/
        │   ├── users.json
        │   ├── orders.json
        │   └── events.part001.json   ← split file
        │   └── events.part002.json
        └── database_two/
            └── ...
```

## Large Collection Splitting

Collections exceeding `--max-file-size` (default 500 MB) are automatically split into numbered parts (`*.part001.json`, `*.part002.json`, …). Splitting is done by line count after export, so document boundaries are never broken — each part file contains complete JSON documents, one per line.

## Error Handling

- The script continues exporting if individual collections fail
- Failed exports are logged to `export-errors.log` in the output directory
- A summary is printed at the end showing successes and failures

## Security

- **Credentials hidden from process list** — `mongoexport` uses a config file instead of passing the URI on the command line, so passwords aren't visible in `ps` output
- **Restrictive file permissions** — `umask 077` ensures exported data is readable only by the owner
- **.env permissions check** — warns if `.env` is readable by other users (recommends `chmod 600`)
- **Path traversal protection** — database and collection names are sanitized before being used in file paths
- **Password masking** — the connection URI is never printed to logs
- **URL encoding** — special characters in passwords are automatically handled
- **Ctrl+C** gracefully aborts the entire export and cleans up temp files

### Recommended .env permissions

```bash
chmod 600 .env
```

## License

[MIT](LICENSE)
