CREATE TABLE IF NOT EXISTS groups(GroupId TEXT PRIMARY KEY,DisplayName TEXT,NameKey TEXT,GroupType TEXT,MembershipType TEXT,Source TEXT,MailEnabled TEXT,OnPremisesSyncEnabled TEXT);
CREATE INDEX IF NOT EXISTS groups_name ON groups(NameKey);
CREATE TABLE IF NOT EXISTS group_members(GroupId TEXT,MemberId TEXT,PRIMARY KEY(GroupId,MemberId));
CREATE TABLE IF NOT EXISTS group_snapshots(GroupId TEXT PRIMARY KEY,ImportedUtc TEXT,SourceFile TEXT,SourceModifiedUtc TEXT,MemberCount INTEGER);
