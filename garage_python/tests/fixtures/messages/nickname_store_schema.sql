-- One NickNameCache key-value store (handledNicknamesKeyStore.db, pendingNicknamesKeyStore.db).
-- PROVISIONAL: from public descriptions, not yet dumped from a real Mac; see chat_db_schema.sql.
CREATE TABLE kvtable (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, key TEXT UNIQUE NOT NULL, value BLOB NOT NULL);
