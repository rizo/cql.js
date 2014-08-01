module cql

##################################################################
# CQLConnection
##################################################################

type CQLConnection
  server  :: String
  port    :: Int
  socket  :: Base.TcpSocket
  buffer  :: IOBuffer
  msg_id  :: Uint8
  replies :: Dict
  pending :: Int

  CQLConnection(srv::String, prt::Int) =
    new(srv, prt, Base.TcpSocket(), IOBuffer(), 1, Dict(), 0);
end

##################################################################

function connect(srv::String = "localhost", prt::Int = 9042)
  con = CQLConnection(srv, prt);
  con.socket = Base.connect(con.server, con.port);
  sendMessage(con, 0x01, {"CQL_VERSION" => "3.0.0"});
  version, id, opcode, len = readServerMessage(con.socket);
  con.pending = 0;
  @assert version == 0x82
  @assert opcode  == 0x02
  @async handleServerMessages(con);
  con 
end

function disconnect(con::CQLConnection)
  while 0 < con.pending
    yield();
  end
  close(con.socket);
  con.socket = Base.TcpSocket();
  con.buffer = IOBuffer();
  con.msg_id = 1;
  con.replies = Dict();
  con.pending = 0;
  con 
end

##################################################################

function readServerMessage(socket::Base.TcpSocket)
  version = read(socket, Uint8);
  flags   = read(socket, Uint8);
  id      = int(read(socket, Uint8));
  opcode  = read(socket, Uint8);
  len     = int(ntoh(read(socket, Uint32)));
  (version, id, opcode, len)
end
  
function handleServerMessage(con::CQLConnection)
  version, id, opcode, len = readServerMessage(con.socket);
  if id > 0 then
    put!(pop!(con.replies, id), 
         (opcode, readbytes(con.socket, len)));
  else
    if opcode == 0x00 then
      println("ERROR: ", bytestring(readbytes(con.socket, len)));
    else
      for i in 1:len
        read(con.socket, Uint8);
      end
    end
  end
  con.pending -= 1;
  nothing
end

function handleServerMessages(con::CQLConnection)
  while !eof(con.socket)
    try
      handleServerMessage(con);
    catch err
      isa(err, EOFError) ? nothing : throw(err);
    end
  end
  nothing
end

### Decoding #####################################################

function decodeString(s)
  strlen = int(ntoh(read(s, Uint16)));
  bytestring(readbytes(s, strlen));
end

function decodeValue(s, nrOfBytes, type_kind, val_type, key_type)
  value = nothing;
  if nrOfBytes < 0 then
    ## null
  elseif type_kind == 0x02 then
    ## Bigint
    value = int(ntoh(read(s, Uint64))); 
  elseif type_kind == 0x09 then
    ## Int
    value = int(ntoh(read(s, Uint32))); 
  elseif type_kind == 0x0B then
    ## Timestamp
    value = ("Timestamp", ntoh(read(s, Uint64)));  
  elseif type_kind == 0x0C then
    ## UUID 
    value = ("UUID", ntoh(read(s, Uint128)));  
  elseif type_kind == 0x0D then
    ## String
    value = bytestring(readbytes(s, nrOfBytes));
  elseif type_kind == 0x20 then
    ## List
    nrOfElements = int(ntoh(read(s, Uint16))); 
    value = Array(Any,nrOfElements);
    for i in 1:nrOfElements
      nrOfBytes = ntoh(read(s, Int16)); 
      val = decodeValue(s, nrOfBytes, val_type, nothing, nothing);
      value[i] = val;
    end
  elseif type_kind == 0x21 then
    ## Map
    nrOfElements = int(ntoh(read(s, Uint16))); 
    value = Dict();
    for i in 1:nrOfElements
      nrOfBytes = ntoh(read(s, Int16)); 
      key = decodeValue(s, nrOfBytes, key_type, nothing, nothing);
      nrOfBytes = ntoh(read(s, Int16)); 
      val = decodeValue(s, nrOfBytes, val_type, nothing, nothing);
      value[key] = val;
    end
  elseif type_kind == 0x22 then
    ## Set
    nrOfElements = int(ntoh(read(s, Uint16))); 
    value = Set();
    for i in 1:nrOfElements
      nrOfBytes = ntoh(read(s, Int16)); 
      val = decodeValue(s, nrOfBytes, val_type, nothing, nothing);
      push!(value, val);
    end
  else
    bytes = readbytes(s, nrOfBytes);
    value = ("*NYI*", type_kind, bytes);
  end
  value
end

function decodeResultRows(s::IOBuffer)
  flags = ntoh(read(s, Uint32)); 
  colcnt = int(ntoh(read(s, Uint32))); 
  global_tables_spec = (flags & 0x0001) != 0;
  
  if global_tables_spec then
    global_ksname = decodeString(s);
    global_tablename = decodeString(s);
  end
  if (flags & 0x0002) != 0 then
    println("d >> ");
  end
  if (flags & 0x0004) != 0 then
    println("e >> ");
  end
  col_type = Array(Uint16, colcnt);
  col_sub_type = Array(Uint16, colcnt);
  col_key_type = Array(Uint16, colcnt);
  for col in 1:colcnt
    if global_tables_spec then
      ksname = global_ksname;
      tablename = global_tablename;
    else
      ksname = decodeString(s);
      tablename = decodeString(s);
    end
    name = decodeString(s);
    type_kind = ntoh(read(s, Uint16)); 
    col_type[col] = type_kind;
    if type_kind == 0x20 || type_kind == 0x22 then
      option_id = ntoh(read(s, Uint16)); 
      col_sub_type[col] = option_id;
    elseif type_kind == 0x21 then
      key_type = ntoh(read(s, Uint16)); 
      value_type = ntoh(read(s, Uint16)); 
      col_key_type[col] = key_type;
      col_sub_type[col] = value_type;
    end
    #println(col, " :: $ksname.$tablename.$name : $type_kind")
  end

  rows_count = int(ntoh(read(s, Uint32))); 
  values = Array(Any,(rows_count));
  for row in 1:rows_count
    row_value = Array(Any,(colcnt));
    values[row] = row_value;
    for col in 1:colcnt
      nrOfBytes = ntoh(read(s, Int32)); 
      value = decodeValue(s, nrOfBytes, col_type[col], 
                          col_sub_type[col], col_key_type[col]);
      row_value[col] = value;
    end
  end
  values
end

function decodeResultMessage(buffer::Array{Uint8})
  s = IOBuffer(buffer);
  kind = int(ntoh(read(s, Uint32))); 
  if kind == 1
    return({"void"});
  elseif kind == 2
    return decodeResultRows(s);
  elseif kind == 3
    return({"set keyspace", decodeString(s)});
  elseif kind == 4
    return({"prepared"});
  elseif kind == 5
    return({"schema change", decodeString(s), 
             decodeString(s), decodeString(s)});
  end
  return {"???"}
end

function decodeMessage(opcode::Uint8, buffer::Array{Uint8})
  if opcode == 0x08 then
    decodeResultMessage(buffer);
  elseif opcode == 0x00 then
    println("ERROR: ", bytestring(buffer));
  else
    opcode
  end
end

### Encoding #####################################################

function cql_encode_string(buf :: IOBuffer, str :: String)
  encStr = bytestring(is_valid_utf8(str) ? str : utf8(str));
  write(buf, hton(uint16(sizeof(encStr))));
  write(buf, encStr);
  nothing
end

function cql_encode_long_string(buf :: IOBuffer, str :: String)
  encStr = bytestring(is_valid_utf8(str) ? str : utf8(str));
  write(buf, hton(uint32(sizeof(encStr))));
  write(buf, encStr);
  nothing
end

##################################################################

function cql_encode(buf :: IOBuffer, dict :: Dict)
  write(buf, hton(uint16(length(dict))));
  for (k,v) in dict
    cql_encode_string(buf, k);
    cql_encode_string(buf, v);
  end
  nothing
end

function cql_encode(buf :: IOBuffer, query :: String)
  cql_encode_long_string(buf, query);
  write(buf, 0x00); 
  write(buf, 0x04); 
  write(buf, 0x00); 
  nothing
end

##################################################################

function sendMessageBody(con  :: CQLConnection, msg)
  buf = con.buffer;
  truncate(buf, 0);
  cql_encode(buf, msg);
  write(con.socket, hton(uint32(buf.size)));
  write(con.socket, takebuf_array(buf));
end

function sendMessage(con::CQLConnection, kind::Uint8,
                     msg, id :: Uint8 = 0x00)
  con.pending += 1;
  write(con.socket, 0x02);
  write(con.socket, 0x00);
  write(con.socket, id);
  write(con.socket, kind);
  sendMessageBody(con, msg);

  flush(con.socket);
  yield();
  nothing
end

function nextReplyID(con :: CQLConnection)
  id :: Uint8 = con.msg_id;
  con.msg_id = 1 + (id + 1) % 99;
  while haskey(con.replies, id)
    yield();
  end
  reply = RemoteRef();
  con.replies[id] = reply;
  (id, reply)
end

##################################################################
### CQL Query
##################################################################

function query(con::CQLConnection, msg::String)
  ## 'Normal' Synchronous Query
  ## Will wait for until all scheduled commands have been executed
  ## Will then send the query and wait for the result.
  ## The processed result is returned as an array or
  ## rows, which are themselves array with the values
  ## for the requested columns.
  sync(con);
  getResult(asyncQuery(con, msg))
end

function command(con::CQLConnection, msg::String)
  ## The same as 'query', but we don't get the result back.
  ## Is a bit faster and uses less memory, because the
  ## reply from the server is neglected.
  sync(con);
  asyncCommand(con, msg)
  sync(con);
  nothing
end

function asyncQuery(con::CQLConnection, msg::String)
  ## An Asynchronous Query
  ## Will send the query to the server and returns 
  ## with a 'future'. After the server has processed the
  ## query and did send back the result, the 'future' will
  ## contain the result. This result can be fetched with
  ## 'getResult', which gives back the result in 
  ## the same format as 'query'.
  id, reply = nextReplyID(con);
  sendMessage(con, 0x07, msg, id);
  reply
end

function asyncCommand(con::CQLConnection, msg::String)
  ## The same as 'command', but asynchronous.
  ## It sends of the command to the server instantly and
  ## neglects the response.
  ## This is the fastest way to execute cql commands, but
  ## no garantees can be given on e.g. the order in which
  ## commands are being executed by the server.
  sendMessage(con, 0x07, msg);
  nothing
end

function getResult(reply)
  ## To fetch the result from a call by asyncQuery.
  ## Will block if the result is not there yet.
  decodeMessage(take!(reply) ...)
end

function sync(con)
  ## Not very usefull, but waits until all messages
  ## that were send to the server where processed and
  ## communicated back.
  ## Can be handy to synchronize or do correct timig tests.
  while 0 < con.pending
    yield();
  end
end

##################################################################
### Tests
##################################################################

function test01()
  ## 'Example of a music service' from 
  ## the manual 'About CQL for Cassandra 2.0'

  c = connect("tilient.net");

  command(c, "CREATE KEYSPACE demo 
                 WITH REPLICATION = {'class' : 'SimpleStrategy',
                                     'replication_factor' : 1};");
  command(c, "USE DEMO;");

  command(c, """
    CREATE TABLE songs ( id uuid PRIMARY KEY,
                title text,
                album text,
                artist text,
                data blob ); """);

  command(c, """
    CREATE TABLE playlists ( id uuid,
                             song_order int,
                             song_id uuid,
                             title text,
                             album text,
                             artist text,
                             PRIMARY KEY (id, song_order)); """);

  command(c, """
    INSERT INTO playlists (id, song_order, song_id, 
                           title, artist, album)
           VALUES (62c36092-82a1-3a00-93d1-46196ee77204, 1,
                   a3e64f8f-bd44-4f28-b8d9-6938726e34d4, 
                   'La Grange', 'ZZ Top', 'Tres Hombres'); """);
  command(c, """
    INSERT INTO playlists (id, song_order, song_id, 
                           title, artist, album)
           VALUES (62c36092-82a1-3a00-93d1-46196ee77204, 2,
                   8a172618-b121-4136-bb10-f665cfc469eb, 
                   'Moving in Stereo', 'Fu Manchu', 
                   'We Must Obey'); """);
  command(c, """
    INSERT INTO playlists (id, song_order, song_id, 
                           title, artist, album)
           VALUES (62c36092-82a1-3a00-93d1-46196ee77204, 3,
                   2b09185b-fb5a-4734-9b56-49077de9edbf, 
                   'Outside Woman Blues', 'Back Door Slam', 
                   'Roll Away'); """);
  command(c, """
    INSERT INTO playlists (id, song_order, song_id, 
                            title, artist, album)
           VALUES (62c36092-82a1-3a00-93d1-46196ee77204, 4,
                   7db1a490-5878-11e2-bcfd-0800200c9a66,
                   'Ojo Rojo', 'Fu Manchu', 
                   'No One Rides for Free'); """);

  println(query(c, 
    "SELECT * FROM playlists;"));
 
  command(c, 
    "CREATE INDEX ON playlists(artist);");
                
  println(query(c, 
    "SELECT * FROM playlists WHERE artist = 'Fu Manchu';"));
                
  println(query(c, """
    SELECT * FROM playlists 
    WHERE id = 62c36092-82a1-3a00-93d1-46196ee77204 
    ORDER BY song_order DESC 
    LIMIT 50; """));
                    
  command(c, 
    "ALTER TABLE songs ADD tags set<text>;");
                    
  command(c, """
     UPDATE songs  SET tags = tags + {'2007'}
       WHERE id = 8a172618-b121-4136-bb10-f665cfc469eb; """); 
     
  command(c, """
     UPDATE songs  SET tags = tags + {'covers'}
       WHERE id = 8a172618-b121-4136-bb10-f665cfc469eb; """); 
     
  command(c, """
     UPDATE songs  SET tags = tags + {'1973'}
       WHERE id = a3e64f8f-bd44-4f28-b8d9-6938726e34d4; """); 
     
  command(c, """
     UPDATE songs  SET tags = tags + {'blues'}
       WHERE id = a3e64f8f-bd44-4f28-b8d9-6938726e34d4; """); 
     
  command(c, """
     UPDATE songs  SET tags = tags + {'rock'}
       WHERE id = 7db1a490-5878-11e2-bcfd-0800200c9a66; """); 
  
  command(c, 
    "ALTER TABLE songs ADD reviews list<text>;");

  command(c, 
    "ALTER TABLE songs ADD venue map<timestamp, text>;");
  
  command(c, """
    UPDATE songs
      SET tags = tags + {'rock'}
      WHERE id = 7db1a490-5878-11e2-bcfd-0800200c9a66;
    """);

  command(c, """
    UPDATE songs
      SET reviews = reviews + [ 'hot dance music' ]
      WHERE id = 7db1a490-5878-11e2-bcfd-0800200c9a66;
    """);

  command(c, """
    INSERT INTO songs (id, venue)
      VALUES (7db1a490-5878-11e2-bcfd-0800200c9a66, 
              { '2013-9-22 12:01' : 'The Fillmore', 
                '2013-10-1 18:00' : 'The Apple Barrel'});
    """);

  println(query(c, "SELECT * FROM SONGS"));
  println(query(c, "SELECT id, tags FROM songs;"));
  println(query(c, "SELECT id, venue FROM songs;"));

  command(c, 
    "CREATE INDEX album_name ON playlists ( album );");
  command(c, 
    "CREATE INDEX title_name ON playlists ( title );");

  println(query(c, """
    SELECT * FROM playlists
      WHERE album = 'Roll Away' 
        AND title = 'Outside Woman Blues'
      ALLOW FILTERING ; """));
  
  command(c, """
    UPDATE songs
      SET title = 'NN'
      WHERE id = 8a172618-b121-4136-bb10-f665cfc469eb;""");
  
  println(query(c, """
    SELECT WRITETIME (title)
      FROM songs
      WHERE id = 8a172618-b121-4136-bb10-f665cfc469eb;"""));
  
  
  ## clean up ##

  command(c, "DROP TABLE songs;");
  command(c, "DROP TABLE playlists;");
  command(c, "DROP KEYSPACE demo;");

  disconnect(c);
  nothing
end

function test02()
  c = connect("tilient.net");

  command(c, "CREATE KEYSPACE demo 
                 WITH REPLICATION = {'class' : 'SimpleStrategy',
                                     'replication_factor' : 1};");
  command(c, "USE DEMO;");
  command(c, "create table person (id int primary key, 
                                      name varchar); ");

  ## Fast, Asynchronous inserts ##
  @time begin
    for id in 1:17000
      asyncCommand(c, 
        "INSERT INTO person (id, name) VALUES ($id, 'hihaho');");
    end
    sync(c);
  end

  println(query(c, "SELECT count(*) from person;")[1][1]);

  command(c, "DROP TABLE person;");
  command(c, "DROP KEYSPACE demo;");
  disconnect(c);
  nothing
end

function test03()
  c = connect("tilient.net");

  command(c, "CREATE KEYSPACE demo 
                 WITH REPLICATION = 
                   {'class' : 'SimpleStrategy',
                    'replication_factor' : 1};");
  command(c, "USE DEMO;");
  command(c, "create table person (id int , 
                                      od int,
                                      name varchar, 
                              PRIMARY KEY (id, od)); ");

  N = 100000;
  
  @time begin
    for i in 1:N
      asyncCommand(c, "INSERT INTO person (id, od, name) 
                           VALUES (1, $i, 'hihaho');");
    end
    sync(c);
  end

  @time begin
    query(c, "select id, od from person 
                  where id = 1
                  order by od asc limit $N;");
    nothing
  end

  command(c, "DROP TABLE person;");
  command(c, "DROP KEYSPACE demo;");
  disconnect(c);
  nothing
end

##################################################################
end
