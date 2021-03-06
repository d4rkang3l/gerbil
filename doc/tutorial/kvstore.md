# A Key-Value Store Server

In this tutorial we develop a key-value store daemon that uses LMDB to
store compressed json objects associated with user keys. The daemon uses
actor RPC to communicate with its clients.

<!-- toc -->

- [Preliminaries](#preliminaries)
- [The RPC Protocol](#the-rpc-protocol)
- [The Server](#the-server)
  * [The main function](#the-main-function)
  * [The server main loop](#the-server-main-loop)
  * [Auxiliary Functions](#auxiliary-functions)
- [A Command-Line Client](#a-command-line-client)
  * [The main function](#the-main-function-1)
  * [Command Implementation](#command-implementation)
- [Example Interaction](#example-interaction)

<!-- tocstop -->

## Preliminaries

This tutorial requires [LMDB](https://en.wikipedia.org/wiki/Lightning_Memory-Mapped_Database).
You need to first install it, and then build the LMDB bindings in stdlib, as they are
not built by default.

So, after installing LMDB, build the LMDB bindings:
```
$ cd $GERBIL_HOME/src
$ sed -i 's/lmdb #f/lmdb #t/' std/build-features.ss
$ ./build_stdlib.sh
...
```

You also need to generate an RPC cookie if you haven't already done so:
```
$ if [ ! -e $HOME/.gerbil/cookie ]; then
  gxi -e '(begin (import :std/actor) (rpc-generate-cookie!))'
fi
```

The source code for the tutorial is available at [$GERBIL_HOME/src/tutorial/kvstore](../../src/tutorial/kvstore).
You can now build the kvstore tutorial so that you can use the programs:
```
$ cd $GERBIL_HOME/src/tutorial/kvstore
$ ./build.ss
... compile proto
... compile kvstored
... compile exe kvstored
... compile kvstorec
... compile exe kvstorec

```

This builds two programs in the tutorial directory: `kvstored`, which is the daemon
and `kvstorec`, which is a simple client to perform basic operations with the daemon.
There is also a build rule for static executables, with `build.ss static`, but we used
here dynamic executables as they are much faster to compile.

## The RPC Protocol

The protocol for communicating with the daemon is defined in
[proto.ss](../../src/tutorial/kvstore/proto.ss):
```
;; A protocol for key-value stores
;; (get key)      -- retrieve object associated with key, or #f if not found
;; (ref key)      -- like get, but result in an exception if not foound
;; (put! key val) -- put an object for a key to the store
;; (remove! key)  -- remove a key
(defproto kvstore
  (get key)
  (ref key)
  (put! key val)
  (remove! key))
```

This defines a protocol with four calls, `get`, `ref`, `put!`, and `remove!`.
The `defproto` macro defines structs and macros for utilizing the protocol in your
programs.

The expansion of the protocol definition looks like this:
```
(begin
  (defsyntax kvstore ...)

  (def kvstore::proto
    (make-!protocol
     'tutorial/kvstore/proto#kvstore
     []
     (hash-copy *default-proto-type-registry*)))
  (hash-put!
   (!protocol-types kvstore::proto)
   (!protocol-id kvstore::proto)
   kvstore::proto)

  (defstruct kvstore.get (key) id: tutorial/kvstore/proto#kvstore.get::t)
  (defsyntax-for-match
    !kvstore.get
    (syntax-rules () ((_ pat ... k) (!call (kvstore.get pat ...) k)))
    (syntax-rules () ((_ key k) (make-!call (make-kvstore.get key) k))))
  (defrules
    !!kvstore.get
    ()
    ((_ dest key) (!!call dest (make-kvstore.get key) (gensym 'k)))
    ((_ dest key timeout: timeo)
     (!!call dest (make-kvstore.get key) (gensym 'k) timeout: timeo))
    ((_ dest key k) (!!call dest (make-kvstore.get key) k))
    ((_ dest key k timeout: timeo)
     (!!call dest (make-kvstore.get key) timeout: timeo)))
  (def (xdr-kvstore.get-read port)
    (xdr-vector-like-read (cut make-object kvstore.get::t <>) 1 port))
  (def (xdr-kvstore.get-write obj port)
    (xdr-vector-like-write obj 1 port))
  (def kvstore.get::xdr
    (make-XDR
     kvstore.get?
     xdr-kvstore.get-read
     xdr-kvstore.get-write))
  (hash-put!
   (!protocol-types kvstore::proto)
   'tutorial/kvstore/proto#kvstore.get::t
   kvstore.get::xdr)

  ...)
```

Here we only show the expansion for the `get` method, but the
generated code for the other methods is similar.

So the macro defines a protocol structure, `kvstore::proto` that
contains the necessary information for the external data
representation of the various structures in the protocol.
Then for each method call `x` in the protocol, it defines a strcuture
for the message `kvstore.x`, a match macro `!kvstore.x` for destructuring
and constructing call messages, and a call macro `!!kvstore.x` for
making synchronous calls.  Then it proceeds to generate code for
marshalling and unmarshalling the messages.

## The Server

The server is defined in [kvstored.ss](../../src/tutorial/kvstore/kvstored.ss).

### The main function

The `main` function is the entry of the program:
```
(def (main . args)
  (def gopt
    (getopt (option 'listen "-l" "--listen"
                    default: "127.0.0.1:9999"
                    help: "rpcd listen address")
            (argument 'path help: "lmdb path")))
  (try
   (let (opt (getopt-parse gopt args))
     (start-logger!)
     (let* ((rpcd (start-rpc-server! (hash-get opt 'listen)
                                     proto: (rpc-cookie-proto)))
            (env (lmdb-open (hash-get opt 'path))))
       (spawn run rpcd env)
       (thread-join! rpcd)))
   (catch (getopt-error? exn)
     (getopt-display-help exn "kvstored" (current-error-port))
     (exit 1))
   (catch (uncaught-exception? exn)
     (display-exception (uncaught-exception-reason exn) (current-error-port)))))
```

The function parses the command line arguments with the `:std/getopt` library, starts
a logger and an rpc server, opens an lmdb environment and spawns the main loop of the
server. It then joins on the rpc server, which should only terminate if the server
failed to start (perhaps because the default port is in use).

### The server main loop

The main loop of the server first registers with the rpc server and then loops
responding to messages using the `<-` reaction macro:
```
(def (run rpcd env)
  (def db (lmdb-open-db env "kvstore"))
  (def nil '#(nil))

  (def (get key)
    ...)

  (def (put! key val)
    ...)

  (def (remove! key)
    ...)

  (rpc-register rpcd 'kvstore kvstore::proto)
  (while #t
    (<- ((!kvstore.get key k)
         (try
          (let* ((val (get key))
                 (val
                  (if (eq? val nil)
                    #f
                    val)))
            (!!value val k))
          (catch (e)
            (log-error "kvstore.get" e)
            (!!error (error-message e) k))))

        ((!kvstore.ref key k)
         (try
          (let (val (get key))
            (if (eq? val nil)
              (!!error "No object associated with key" k)
              (!!value val k)))
          (catch (e)
            (log-error "kvstore.ref" e)
            (!!error (error-message e) k))))

        ((!kvstore.put! key val k)
         (try
          (put! key val)
          (!!value (void) k)
          (catch (e)
            (log-error "kvstore.put!" e)
            (!!error (error-message e) k))))

        ((!kvstore.remove! key k)
         (try
          (remove! key)
          (!!value (void) k)
          (catch (e)
            (log-error "kvstore.remove!" e)
            (!!error (error-message e) k))))

        (what
         (warning "Unexpected message: ~a " what)))))
```

### Auxiliary Functions

The main loop uses 3 auxiliary functions to implement the low level details of interacting
with the key-value store:
```
(def (run rpcd env)
  ...

  (def (get key)
    (let (txn (lmdb-txn-begin env))
      (try
       (let* ((bytes (lmdb-get txn db key))
              (val (if bytes
                     (call-with-input-u8vector (uncompress bytes) read-json)
                     nil)))
         (lmdb-txn-commit txn)
         val)
       (catch (e)
         (lmdb-txn-abort txn)
         (raise e)))))

  (def (put! key val)
    (let* ((bytes (call-with-output-u8vector [] (cut write-json val <>)))
           (bytes (compress bytes))
           (txn (lmdb-txn-begin env)))
      (try
       (lmdb-put txn db key bytes)
       (lmdb-txn-commit txn)
       (catch (e)
         (lmdb-txn-abort txn)
         (raise e)))))

  (def (remove! key)
    (let (txn (lmdb-txn-begin env))
      (try
       (lmdb-del txn db key)
       (lmdb-txn-commit txn)
       (catch (e)
         (lmdb-txn-abort txn)
         (raise e)))))

  ...)
```

## A Command-Line Client

There is a command-line client for our daemon, defined in [kvstorec.ss](../../src/tutorial/kvstore/kvstorec.ss).

### The main function

The `main` function is the entry of the program:
```
(def (main . args)
  (def getcmd
    (command 'get help: "get the json object associated with key or false if none is"
             (argument 'key help: "object key, a string")))
  (def refcmd
    (command 'ref help: "get the json object associated with key or error"
             (argument 'key help: "object key, a string")))
  (def putcmd
    (command 'put help: "put a json object to store"
             (argument 'key help: "object key, a string")
             (argument 'file help: "json file")))
  (def delcmd
    (command 'remove help: "remove an object from the store"
             (argument 'key help: "object key, a string")))
  (def helpcmd
    (command 'help help: "display usage help"
             (optional-argument 'command value: string->symbol)))

  (def gopt
    (getopt (option 'server "-s" "--server"
                    default: "127.0.0.1:9999"
                    help: "server rpc address")
            getcmd
            refcmd
            putcmd
            delcmd
            helpcmd))

  (try
   (let ((values cmd opt) (getopt-parse gopt args))
     (case cmd
       ((get) (kvstore-get opt))
       ((ref) (kvstore-ref opt))
       ((put) (kvstore-put! opt))
       ((remove) (kvstore-remove! opt))
       ((help)
        (let (topic
              (hash-get
               (hash-eq (get getcmd)
                        (ref refcmd)
                        (put putcmd)
                        (remove delcmd)
                        (help helpcmd))
               (hash-get opt 'command)))
          (getopt-display-help (or topic gopt) "kvstorec")))))
   (catch (getopt-error? exn)
     (getopt-display-help exn "kvstorec" (current-error-port))
     (exit 1))
   (catch (remote-error? exn)
     (displayln (error-message exn))
     (exit 1))))
```

This program works by accepting commands from the user in the command line, using
the `:std/getopt` library. There are four possible commands, for the four possible
calls in the protocol.

### Command Implementation

The implementation of the four commands is very simple: each constructs a remote
handle for the server, using the `kvstore-connect` auxiliary funciton, and then
proceeds to call the server with RPC:
```
(def (kvstore-connect opt)
  (let (rpcd (start-rpc-server! proto: (rpc-cookie-proto)))
    (rpc-connect rpcd 'kvstore (hash-get opt 'server) kvstore::proto)))

(def (kvstore-get opt)
  (let* ((remote (kvstore-connect opt))
         (val (!!kvstore.get remote (hash-get opt 'key))))
    (write-json val)
    (newline)))

(def (kvstore-ref opt)
  (let* ((remote (kvstore-connect opt))
         (val (!!kvstore.ref remote (hash-get opt 'key))))
    (write-json val)
    (newline)))

(def (kvstore-put! opt)
  (let* ((val (call-with-input-file (hash-get opt 'file) read-json))
         (remote (kvstore-connect opt)))
    (!!kvstore.put! remote (hash-get opt 'key) val)))

(def (kvstore-remove! opt)
  (let (remote (kvstore-connect opt))
    (!!kvstore.remove! remote (hash-get opt 'key))))
```

## Example Interaction

First let's start the server using `/tmp/kvstore.db` for the database:
```
$ ./kvstored /tmp/kvstore.db
```

Then we can interact with the server using the client in another shell.
First, let's put an object in the store:
```
$ cat > /tmp/foo.json
{
 "head": "I am a walrus~",
 "body": {
   "value": "and this is my body"
 }
}
$ ./kvstorec put foo /tmp/foo.json
```

We can then retrieve our object:
```
$ ./kvstorec get foo
{"body": {"value": "and this is my body"}, "head": "I am a walrus~"}
```

We can then delete our object:
```
$ ./kvstorec remove foo
```

If we try to retrieve the object again, we get a `false`:
```
$ ./kvstorec get foo
false
```

If we want an error if the object does not exist instead of a default `false`
response, we can use the `ref` command:
```
$ ./kvstorec ref foo
remote error: No object associated with key
$ echo $?
1
```
