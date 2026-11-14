# NFS 顶层目录属主的检查

At inspection on 2026-10-21,
`/core-data` and `/core-data/archive` were `0:0` mode 755,
`/core-data/backups` was `0:100` mode 755, and `/media-data` was
`105:100` mode 755; `wenxin` was `1000:998`. A read/write export does not
grant that account permission to create files in these top-level directories.
