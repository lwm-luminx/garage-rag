-- One NickNameCache key-value store (handledNicknamesKeyStore.db, pendingNicknamesKeyStore.db).
-- PROVISIONAL: from public descriptions, not yet dumped from a real NickNameCache store. chat.db has a
-- kvtable of its own with exactly this DDL (see chat_db_schema.sql).
CREATE TABLE kvtable (ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, key TEXT UNIQUE NOT NULL, value BLOB NOT NULL);
