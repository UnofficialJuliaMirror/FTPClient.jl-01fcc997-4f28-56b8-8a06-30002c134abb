# FTPClient
FTP client based on [LibCURL.jl](https://github.com/JuliaWeb/LibCURL.jl).

### Usage

`ftp_init()` and  `ftp_cleanup()` need to be used once per session.

Functions for non-persistent connection:
```julia
ftp_get(file_name::String, options::RequestOptions, save_path::String)
ftp_put(file_name::String, file::IO, options::RequestOptions)
ftp_command(cmd::String, options::RequestOptions)
```
- These functions all establish a connection, perform the desired operation then close the connection and return a `Response` object. Any data retrieved from server is in `Response.body`.

    ```julia
    type Response
        body::IO
        headers::Vector{String}
        code::Int
        total_time::FloatingPoint
        bytes_recd::Int
    end
    ```

Functions for persistent connection:
```julia
ftp_connect(options::RequestOptions)
ftp_get(ctxt::ConnContext, file_name::String, save_path::String)
ftp_put(ctxt::ConnContext, file_name::String, file::IO)
ftp_command(ctxt::ConnContext, cmd::String)
ftp_close_connection(ctxt::ConnContext)
```
- These functions all return a `Response` object, except `ftp_close_connection`, which does not return anything. Any data retrieved from server is in `Response.body`.

    ```julia
    type ConnContext
        curl::Ptr{CURL}
        url::String
        rd::ReadData
        wd::WriteData
        resp::Response
        options::RequestOptions
        close_ostream::Bool
    end
    ```

- `url` is of the form "localhost" or "127.0.0.1"
- `cmd` is of the form "PWD" or "CWD Documents/", and must be a valid FTP command
- `file_name` is both the name of the file that will be retrieved/uploaded and the name it will be saved as
- `options` is a `RequestOptions` object

    ```julia
    type RequestOptions
        blocking::Bool
        implicit::Bool
        ssl::Bool
        verify_peer::Bool
        active_mode::Bool
        headers::Vector{Tuple}
        username::String
        passwd::String
        url::String
    end
    ```
    - `blocking`: default is true
    - `implicit`: use implicit security, default is false
    - `ssl`: use FTPS, default is false
    - `verify_peer`: verify authenticity of peer's certificate, default is true
    - `active_mode`: use active mode to establish data connection, default is false

### Examples

Using non-peristent connection and FTPS with implicit security:
```julia
using FTPClient

ftp_init()
options = RequestOptions(ssl=true, implicit=true, username="user1", passwd="1234", url="localhost")

resp = ftp_get("download_file.txt", options)
io_buffer = resp.body

resp = ftp_get("download_file.txt", options, "Documents/downloaded_file.txt")
io_stream = resp.body

file = open("upload_file.txt")
resp = ftp_put("upload_file.txt", file, options)
close(file)

resp = ftp_command("LIST", options)
dir = resp.body

ftp_cleanup()
```

Using persistent connection and FTPS with explicit security:
```julia
using FTPClient

ftp_init()
options = RequestOptions(ssl=true, username="user2", passwd="5678", url="localhost")

ctxt = ftp_connect(options)

resp = ftp_get(ctxt, "download_file.txt")
io_buffer = resp.body

resp = ftp_get(ctxt, "download_file.txt", "Documents/downloaded_file.txt")
io_stream = resp.body

resp = ftp_command(ctxt, "CWD Documents/")

file = open("upload_file.txt")
resp = ftp_put(ctxt, "upload_file.txt", file)
close(file)

ftp_close_connection(ctxt)

ftp_cleanup()
```

### Running Tests

Tests must be run from the main directory

`julia test/runtests.jl <use_ssl> <use_implicit> <username> <password>`

To set up the mock FTP server
- Add the [JavaCall.jl](https://github.com/aviks/JavaCall.jl) package with `Pkg.add("JavaCall”)`
- Build dependencies via `Pkg.build("FTPClient")`

The mock FTP server does not work with SSL. To run the non-ssl tests:
    `julia test/runtests.jl`

The ssl tests can be run if you have a local ftp server set up.
- To run the tests using implicit security: `julia test/runtests.jl true true <username> <password>`
- To run the tests using explicit security: `julia test/runtests.jl true false <username> <password>`

