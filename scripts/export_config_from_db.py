#!/usr/bin/env python3
"""
Simple export script: read key_values table from sqlite DB and create config.generated.yaml
Usage: python3 scripts/export_config_from_db.py [path/to/filecodebox.db] [output.yaml]
"""
import sqlite3
import sys
import yaml
from pathlib import Path

DB_PATH = sys.argv[1] if len(sys.argv) > 1 else 'data/filecodebox.db'
OUT_PATH = sys.argv[2] if len(sys.argv) > 2 else 'config.generated.yaml'

conn = sqlite3.connect(DB_PATH)
cur = conn.cursor()
cur.execute("SELECT key, value FROM key_values")
rows = cur.fetchall()

cfg = {
    'base': {},
    'database': {},
    'storage': {},
    'user': {},
    'mcp': {},
    'ui': {},
}

for k, v in rows:
    if k == 'name': cfg['base']['name'] = v
    elif k == 'description': cfg['base']['description'] = v
    elif k == 'host': cfg['base']['host'] = v
    elif k == 'port':
        try:
            cfg['base']['port'] = int(v)
        except:
            cfg['base']['port'] = v
    elif k == 'data_path': cfg['base']['data_path'] = v
    elif k == 'production': cfg['base']['production'] = (v == 'true' or v == '1')
    elif k.startswith('database_'):
        sub = k.split('database_',1)[1]
        cfg['database'][sub] = int(v) if v.isdigit() else v
    elif k.startswith('storage.'):
        # storage keys may be storage.default or storage.local.path etc
        parts = k.split('.')
        if len(parts) >= 2:
            section = parts[1]
            if section not in cfg['storage']:
                cfg['storage'][section] = {}
            if len(parts) == 2:
                cfg['storage'][section] = v
            else:
                # e.g. storage.local.path
                subkey = parts[2]
                cfg['storage'][section][subkey] = v
    elif k.startswith('user_'):
        sub = k.split('user_',1)[1]
        try:
            cfg['user'][sub] = int(v)
        except:
            cfg['user'][sub] = (v == 'true' or v == '1') if v in ['0','1','true','false'] else v
    elif k.startswith('mcp_'):
        sub = k.split('mcp_',1)[1]
        try:
            cfg['mcp'][sub] = int(v)
        except:
            cfg['mcp'][sub] = (v == 'true' or v == '1') if v in ['0','1','true','false'] else v
    elif k.startswith('theme') or k.startswith('notify') or k.startswith('page_'):
        cfg['ui'][k] = v
    else:
        # fall back: put in ui
        cfg['ui'][k] = v

with open(OUT_PATH, 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

print(f"Wrote {OUT_PATH} from {DB_PATH}")
