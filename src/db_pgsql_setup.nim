# Ena - db_pgsql_setup.nim
# Almost all of the SQL statements are copied from Fuuka/Asagi for compatibility.

import db_postgres
import strformat, strutils

proc db_connect*(DB_HOST, DB_USERNAME, DB_PASSWORD, DB_NAME: string): DbConn =
  result = open(DB_HOST, DB_USERNAME, DB_PASSWORD, DB_NAME)
  discard result.setEncoding("utf8mb4")

proc create_tables*(board_name: string, db: DbConn) =
  db.exec(sql"START TRANSACTION")

  db.exec(sql(fmt"""CREATE TABLE IF NOT EXISTS "{board_name}_threads" (
    thread_num integer NOT NULL,
    time_op integer NOT NULL,
    time_last integer NOT NULL,
    time_bump integer NOT NULL,
    time_ghost integer DEFAULT NULL,
    time_ghost_bump integer DEFAULT NULL,
    time_last_modified integer NOT NULL,
    nreplies integer NOT NULL DEFAULT '0',
    nimages integer NOT NULL DEFAULT '0',
    sticky boolean DEFAULT false NOT NULL,
    locked boolean DEFAULT false NOT NULL,
  
    PRIMARY KEY (thread_num)
  )"""))

  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_threads_time_op_index\" on \"{board_name}_threads\" (time_op)"));
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_threads_time_bump_index\" on \"{board_name}_threads\" (time_bump)"));
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_threads_time_ghost_bump_index\" on \"{board_name}_threads\" (time_ghost_bump)"));
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_threads_time_last_modified_index\" on \"{board_name}_threads\" (time_last_modified)"));
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_threads_sticky_index\" on \"{board_name}_threads\" (sticky)"));
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_threads_locked_index\" on \"{board_name}_threads\" (locked)"));

  db.exec(sql(fmt"""CREATE TABLE IF NOT EXISTS "{board_name}_users" (
    user_id SERIAL NOT NULL,
    name character varying(100) NOT NULL DEFAULT '',
    trip character varying(25) NOT NULL DEFAULT '',
    firstseen integer NOT NULL,
    postcount integer NOT NULL,
  
    PRIMARY KEY (user_id),
    UNIQUE (name, trip)
  )"""))

  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_users_firstseen_index\" on \"{board_name}_users\" (firstseen)"));
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_users_postcount_index\" on \"{board_name}_users\" (postcount)"));

  db.exec(sql(fmt"""CREATE TABLE IF NOT EXISTS "{board_name}_images" (
    media_id SERIAL NOT NULL,
    media_hash character varying(25) NOT NULL,
    media character varying(20),
    preview_op character varying(20),
    preview_reply character varying(20),
    total integer NOT NULL DEFAULT '0',
    banned smallint NOT NULL DEFAULT '0',
  
    PRIMARY KEY (media_id),
    UNIQUE (media_hash)
  )"""))

  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_images_total_index\" on \"{board_name}_images\" (total)"));
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_images_banned_index\" ON \"{board_name}_images\" (banned)"));

  db.exec(sql(fmt"""CREATE TABLE IF NOT EXISTS "{board_name}_daily" (
    day integer NOT NULL,
    posts integer NOT NULL,
    images integer NOT NULL,
    sage integer NOT NULL,
    anons integer NOT NULL,
    trips integer NOT NULL,
    names integer NOT NULL,
  
    PRIMARY KEY (day)
  )"""))

  db.exec(sql(fmt"""CREATE TABLE IF NOT EXISTS "{board_name}" (
    doc_id SERIAL NOT NULL,
    media_id integer,
    poster_ip numeric(39,0) DEFAULT 0 NOT NULL,
    num integer NOT NULL,
    subnum integer NOT NULL,
    thread_num integer DEFAULT 0 NOT NULL,
    op boolean DEFAULT false NOT NULL,
    "timestamp" integer NOT NULL,
    "timestamp_expired" integer NOT NULL,
    preview_orig character varying(20),
    preview_w integer DEFAULT 0 NOT NULL,
    preview_h integer DEFAULT 0 NOT NULL,
    media_filename text,
    media_w integer DEFAULT 0 NOT NULL,
    media_h integer DEFAULT 0 NOT NULL,
    media_size integer DEFAULT 0 NOT NULL,
    media_hash character varying(25),
    media_orig character varying(20),
    spoiler boolean DEFAULT false NOT NULL,
    deleted boolean DEFAULT false NOT NULL,
    capcode character(1) DEFAULT 'N' NOT NULL,
    email character varying(100),
    name character varying(100),
    trip character varying(25),
    title character varying(100),
    comment text,
    delpass text,
    sticky boolean DEFAULT false NOT NULL,
    locked boolean DEFAULT false NOT NULL,
    poster_hash character varying(8),
    poster_country character varying(2),
    exif text,
  
    PRIMARY KEY (doc_id),
    FOREIGN KEY (media_id) REFERENCES "{board_name}_images"(media_id),
    UNIQUE (num, subnum)
  )"""))

  db.exec(sql(&"ALTER TABLE \"{board_name}\" DROP CONSTRAINT IF EXISTS \"{board_name}_media_id_fkey\""))

  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_num_index\" on \"{board_name}\" (num)"))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_subnum_index\" on \"{board_name}\" (subnum)"))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_thread_num_index\" on \"{board_name}\" (thread_num)"))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_op_index\" on \"{board_name}\" (op)"))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_media_hash_index\" on \"{board_name}\" (media_hash) "))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_media_orig_index\" on \"{board_name}\" (media_orig) "))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_name_trip_index\" on \"{board_name}\" (name,trip)"))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_name_index\" on \"{board_name}\" (name)"))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_trip_index\" on \"{board_name}\" (trip)"))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_email_index\" on \"{board_name}\" (email)"))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_poster_ip_index\" on \"{board_name}\" (poster_ip)"))
  db.exec(sql(&"CREATE INDEX IF NOT EXISTS \"{board_name}_timestamp_index\" on \"{board_name}\" (timestamp)"))

  db.exec(sql(fmt"""CREATE TABLE IF NOT EXISTS "{board_name}_deleted" (
    LIKE "{board_name}" INCLUDING ALL
  )"""));

  db.exec(sql"COMMIT")

proc create_procedures*(board_name: string, db: DbConn) =
  db.exec(sql"START TRANSACTION")

  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_update_thread"(n_row "{board_name}") RETURNS void AS $$
  BEGIN
    UPDATE
      "{board_name}_threads" AS op
    SET
      time_last = (
        COALESCE(GREATEST(
          op.time_op,
          (SELECT MAX(timestamp) FROM "{board_name}" re WHERE
            re.thread_num = $1.thread_num AND re.subnum = 0)
        ), op.time_op)
      ),
      time_bump = (
        COALESCE(GREATEST(
          op.time_op,
          (SELECT MAX(timestamp) FROM "{board_name}" re WHERE
            re.thread_num = $1.thread_num AND (re.email <> 'sage' OR re.email IS NULL)
            AND re.subnum = 0)
        ), op.time_op)
      ),
      time_ghost = (
        SELECT MAX(timestamp) FROM "{board_name}" re WHERE
          re.thread_num = $1.thread_num AND re.subnum <> 0
      ),
      time_ghost_bump = (
        SELECT MAX(timestamp) FROM "{board_name}" re WHERE
          re.thread_num = $1.thread_num AND re.subnum <> 0 AND (re.email <> 'sage' OR
            re.email IS NULL)
      ),
      time_last_modified = (
        COALESCE(GREATEST(
          op.time_op,
          (SELECT GREATEST(MAX(timestamp), MAX(timestamp_expired)) FROM "{board_name}" re WHERE
            re.thread_num = $1.thread_num)
        ), op.time_op)
      ),
      nreplies = (
        SELECT COUNT(*) FROM "{board_name}" re WHERE
          re.thread_num = $1.thread_num
      ),
      nimages = (
        SELECT COUNT(media_hash) FROM "{board_name}" re WHERE
          re.thread_num = $1.thread_num
      )
      WHERE op.thread_num = $1.thread_num;
  END; 
  $$ LANGUAGE plpgsql;"""))
    
    
  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_create_thread"(n_row "{board_name}") RETURNS void AS $$
  BEGIN
    IF n_row.op = false THEN RETURN; END IF;
    INSERT INTO "{board_name}_threads" SELECT $1.num, $1.timestamp, $1.timestamp,
        $1.timestamp, NULL, NULL, $1.timestamp, 0, 0, false, false WHERE NOT EXISTS (SELECT 1 FROM "{board_name}_threads" WHERE thread_num=$1.num);
    RETURN;
  END;
  $$ LANGUAGE plpgsql;"""))
  
  
  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_delete_thread"(n_parent integer) RETURNS void AS $$
  BEGIN
    DELETE FROM "{board_name}_threads" WHERE thread_num = n_parent;
    RETURN;
  END;
  $$ LANGUAGE plpgsql;"""))
  
  
  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_insert_image"(n_row "{board_name}") RETURNS integer AS $$
  DECLARE
      img_id INTEGER;
  BEGIN
    INSERT INTO "{board_name}_images"
      (media_hash, media, preview_op, preview_reply, total)
      SELECT n_row.media_hash, n_row.media_orig, NULL, NULL, 0
      WHERE NOT EXISTS (SELECT 1 FROM "{board_name}_images" WHERE media_hash = n_row.media_hash);
  
    IF n_row.op = true THEN
      UPDATE "{board_name}_images" SET total = (total + 1), preview_op = COALESCE(preview_op, n_row.preview_orig) WHERE media_hash = n_row.media_hash RETURNING media_id INTO img_id;
    ELSE
      UPDATE "{board_name}_images" SET total = (total + 1), preview_reply = COALESCE(preview_reply, n_row.preview_orig) WHERE media_hash = n_row.media_hash RETURNING media_id INTO img_id;
    END IF;
    RETURN img_id;
  END;
  $$ LANGUAGE plpgsql;"""))
    
    
  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_delete_image"(n_media_id integer) RETURNS void AS $$
  BEGIN
    UPDATE "{board_name}_images" SET total = (total - 1) WHERE id = n_media_id;
  END;
  $$ LANGUAGE plpgsql;"""))
  
  
  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_insert_post"(n_row "{board_name}") RETURNS void AS $$
  DECLARE
    d_day integer;
    d_image integer;
    d_sage integer;
    d_anon integer;
    d_trip integer;
    d_name integer;
  BEGIN
    d_day := FLOOR($1.timestamp/86400)*86400;
    d_image := CASE WHEN $1.media_hash IS NOT NULL THEN 1 ELSE 0 END;
    d_sage := CASE WHEN $1.email = 'sage' THEN 1 ELSE 0 END;
    d_anon := CASE WHEN $1.name = 'Anonymous' AND $1.trip IS NULL THEN 1 ELSE 0 END;
    d_trip := CASE WHEN $1.trip IS NOT NULL THEN 1 ELSE 0 END;
    d_name := CASE WHEN COALESCE($1.name <> 'Anonymous' AND $1.trip IS NULL, TRUE) THEN 1 ELSE 0 END;
  
    INSERT INTO "{board_name}_daily"
      SELECT d_day, 0, 0, 0, 0, 0, 0
      WHERE NOT EXISTS (SELECT 1 FROM "{board_name}_daily" WHERE day = d_day);
  
    UPDATE "{board_name}_daily" SET posts=posts+1, images=images+d_image,
      sage=sage+d_sage, anons=anons+d_anon, trips=trips+d_trip,
      names=names+d_name WHERE day = d_day;
  
    IF (SELECT trip FROM "{board_name}_users" WHERE trip = $1.trip) IS NOT NULL THEN
      UPDATE "{board_name}_users" SET postcount=postcount+1,
        firstseen = LEAST($1.timestamp, firstseen),
        name = COALESCE($1.name, '')
        WHERE trip = $1.trip;
    ELSE
      INSERT INTO "{board_name}_users" (name, trip, firstseen, postcount)
        SELECT COALESCE($1.name,''), COALESCE($1.trip,''), $1.timestamp, 0
        WHERE NOT EXISTS (SELECT 1 FROM "{board_name}_users" WHERE name = COALESCE($1.name,'') AND trip = COALESCE($1.trip,''));
  
      UPDATE "{board_name}_users" SET postcount=postcount+1,
        firstseen = LEAST($1.timestamp, firstseen)
        WHERE name = COALESCE($1.name,'') AND trip = COALESCE($1.trip,'');
    END IF;
  END;
  $$ LANGUAGE plpgsql;"""))
  
  
  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_delete_post"(n_row "{board_name}") RETURNS void AS $$
  DECLARE
    d_day integer;
    d_image integer;
    d_sage integer;
    d_anon integer;
    d_trip integer;
    d_name integer;
  BEGIN
    d_day := FLOOR($1.timestamp/86400)*86400;
    d_image := CASE WHEN $1.media_hash IS NOT NULL THEN 1 ELSE 0 END;
    d_sage := CASE WHEN $1.email = 'sage' THEN 1 ELSE 0 END;
    d_anon := CASE WHEN $1.name = 'Anonymous' AND $1.trip IS NULL THEN 1 ELSE 0 END;
    d_trip := CASE WHEN $1.trip IS NOT NULL THEN 1 ELSE 0 END;
    d_name := CASE WHEN COALESCE($1.name <> 'Anonymous' AND $1.trip IS NULL, TRUE) THEN 1 ELSE 0 END;
  
    UPDATE "{board_name}_daily" SET posts=posts-1, images=images-d_image,
      sage=sage-d_sage, anons=anons-d_anon, trips=trips-d_trip,
      names=names-d_name WHERE day = d_day;
  
    IF (SELECT trip FROM "{board_name}_users" WHERE trip = $1.trip) IS NOT NULL THEN
      UPDATE "{board_name}_users" SET postcount=postcount-1,
        firstseen = LEAST($1.timestamp, firstseen)
        WHERE trip = $1.trip;
    ELSE
      UPDATE "{board_name}_users" SET postcount=postcount-1,
        firstseen = LEAST($1.timestamp, firstseen)
        WHERE (name = $1.name OR $1.name IS NULL) AND (trip = $1.trip OR $1.trip IS NULL);
    END IF;
  END;
  $$ LANGUAGE plpgsql;"""))
      
  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_before_insert"() RETURNS trigger AS $$
  BEGIN
    IF NEW.media_hash > ' ' THEN
      SELECT "{board_name}_insert_image"(NEW) INTO NEW.media_id;
    END IF;
    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;"""))
      
  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_after_insert"() RETURNS trigger AS $$
  BEGIN
    IF NEW.op = true THEN
      PERFORM "{board_name}_create_thread"(NEW);
    END IF;
    PERFORM "{board_name}_update_thread"(NEW);
    RETURN NULL;
  END;
  $$ LANGUAGE plpgsql;"""))
      
  db.exec(sql(fmt"""CREATE OR REPLACE FUNCTION "{board_name}_after_del"() RETURNS trigger AS $$
  BEGIN
    PERFORM "{board_name}_update_thread"(OLD);
    IF OLD.op = true THEN
      PERFORM "{board_name}_delete_thread"(OLD.num);
    END IF;
    IF OLD.media_hash IS NOT NULL THEN
      PERFORM "{board_name}_delete_image"(OLD.media_id);
    END IF;
    RETURN NULL;
  END;
  $$ LANGUAGE plpgsql;"""))

  db.exec(sql(&"DROP TRIGGER IF EXISTS \"{board_name}_after_delete\" ON \"{board_name}\""))
  db.exec(sql(&"CREATE TRIGGER \"{board_name}_after_delete\" AFTER DELETE ON \"{board_name}\" FOR EACH ROW EXECUTE PROCEDURE \"{board_name}_after_del\"()"))
  
  db.exec(sql(&"DROP TRIGGER IF EXISTS \"{board_name}_before_insert\" ON \"{board_name}\""))
  db.exec(sql(&"CREATE TRIGGER \"{board_name}_before_insert\" BEFORE INSERT ON \"{board_name}\" FOR EACH ROW EXECUTE PROCEDURE \"{board_name}_before_insert\"()"))
  
  db.exec(sql(&"DROP TRIGGER IF EXISTS \"{board_name}_after_insert\" ON \"{board_name}\""))
  db.exec(sql(&"CREATE TRIGGER \"{board_name}_after_insert\" AFTER INSERT ON \"{board_name}\" FOR EACH ROW EXECUTE PROCEDURE \"{board_name}_after_insert\"()"))

  db.exec(sql"COMMIT")