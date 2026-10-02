package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"

	_ "modernc.org/sqlite"
	"gopkg.in/yaml.v3"
)

func main() {
	dbPath := flag.String("db", "data/filecodebox.db", "path to sqlite db")
	out := flag.String("out", "config.generated.yaml", "output yaml file")
	flag.Parse()

	if _, err := os.Stat(*dbPath); err != nil {
		log.Fatalf("db not found: %v", err)
	}

	db, err := sql.Open("sqlite", *dbPath)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer func() { _ = db.Close() }()

	r, err := db.Query("SELECT key, value FROM key_values")
	if err != nil {
		log.Fatalf("query: %v", err)
	}
	defer func() { _ = r.Close() }()

	cfg := make(map[string]map[string]interface{})
	cfg["base"] = map[string]interface{}{}
	cfg["database"] = map[string]interface{}{}
	cfg["storage"] = map[string]interface{}{}
	cfg["user"] = map[string]interface{}{}
	cfg["mcp"] = map[string]interface{}{}
	cfg["ui"] = map[string]interface{}{}

	for r.Next() {
		var k, v string
		if err := r.Scan(&k, &v); err != nil {
			log.Printf("scan err: %v", err)
			continue
		}

		// basic mapping heuristics similar to previous python script
		if k == "name" || k == "description" || k == "host" || k == "port" || k == "data_path" || k == "production" {
			cfg["base"][k] = parseValue(v)
			continue
		}
		if len(k) >= 9 && k[:9] == "database_" {
			sub := k[9:]
			cfg["database"][sub] = parseValue(v)
			continue
		}
		if len(k) >= 6 && k[:5] == "user_" {
			sub := k[5:]
			cfg["user"][sub] = parseValue(v)
			continue
		}
		if len(k) >= 4 && k[:4] == "mcp_" {
			sub := k[4:]
			cfg["mcp"][sub] = parseValue(v)
			continue
		}
		if len(k) >= 8 && k[:8] == "storage." {
			// storage.<section> or storage.<section>.<key>
			parts := splitN(k, '.', 3)
			if len(parts) >= 2 {
				section := parts[1]
				if len(parts) == 2 {
					cfg["storage"][section] = parseValue(v)
				} else {
					// nested map
					m, ok := cfg["storage"][section].(map[string]interface{})
					if !ok {
						m = map[string]interface{}{}
					}
					m[parts[2]] = parseValue(v)
					cfg["storage"][section] = m
				}
			}
			continue
		}
		// fallback to ui
		cfg["ui"][k] = parseValue(v)
	}

	outF, err := os.Create(*out)
	if err != nil {
		log.Fatalf("create out: %v", err)
	}
	enc := yaml.NewEncoder(outF)
	enc.SetIndent(2)
	if err := enc.Encode(cfg); err != nil {
		log.Fatalf("encode yaml: %v", err)
	}
	if err := outF.Close(); err != nil {
		log.Printf("warning: failed to close outF: %v", err)
	}
	fmt.Printf("wrote %s\n", *out)
}

func splitN(s string, sep byte, n int) []string {
	res := []string{}
	cur := ""
	count := 0
	for i := 0; i < len(s); i++ {
		if s[i] == sep {
			res = append(res, cur)
			cur = ""
			count++
			if count >= n-1 {
				res = append(res, s[i+1:])
				return res
			}
		} else {
			cur += string(s[i])
		}
	}
	res = append(res, cur)
	return res
}

func parseValue(v string) interface{} {
	// try int
	var i int
	_, err := fmt.Sscanf(v, "%d", &i)
	if err == nil {
		return i
	}
	if v == "true" || v == "1" {
		return true
	}
	if v == "false" || v == "0" {
		return false
	}
	return v
}
