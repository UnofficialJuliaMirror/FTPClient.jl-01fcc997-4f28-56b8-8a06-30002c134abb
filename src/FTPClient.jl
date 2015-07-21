module FTPClient

using LibCURL
using Debug

import Base.convert, Base.show

export RequestOptions, Response
export ftp_init, ftp_cleanup, ftp_connect, ftp_close_connection, ftp_get, ftp_put, ftp_command

##############################
# Type definitions
##############################

type RequestOptions
    blocking::Bool
    implicit::Bool
    ssl::Bool
    verify_peer::Bool
    active_mode::Bool
    username::String
    passwd::String

    RequestOptions(; blocking=true, implicit=false, ssl=false, verify_peer=true, active_mode=false, username="", passwd="") = new(blocking, implicit, ssl, verify_peer, active_mode, username, passwd)
end

type Response
    body
    headers::Vector{String}
    code::Int
    total_time
    bytes_recd::Int

    Response() = new(IOBuffer(), Vector{String}(), 0, 0.0, 0)
end

function show(io::IO, o::Response)
    println(io, "Response Code :", o.code)
    println(io, "Request Time  :", o.total_time)
    println(io, "Headers       :", o.headers)
    println(io, "Length of body: ", o.bytes_recd)
end

type ReadData
    typ::Symbol
    src::Any
    str::String
    offset::Csize_t
    sz::Csize_t

    ReadData() = new(:undefined, false, "", 0, 0)
end

type WriteData
    typ::Symbol
    src::Any
    name::String

    WriteData() = new(:undefined, nothing, "")
end

type ConnContext
    curl::Ptr{CURL}
    url::String
    rd::ReadData
    wd::WriteData
    resp::Response
    options::RequestOptions
    close_ostream::Bool

    ConnContext(options::RequestOptions) = new(C_NULL, "", ReadData(), WriteData(), Response(), options, false)
end


##############################
# Callbacks
##############################

function write_file_cb(buff::Ptr{Uint8}, sz::Csize_t, n::Csize_t, p_ctxt::Ptr{Void})
    # println("@write_file_cb")
    ctxt = unsafe_pointer_to_objref(p_ctxt)
    nbytes = sz * n

    if ctxt.wd.typ == :io
        ctxt.wd.src = Base.open(ctxt.wd.name, "w")
    end

    write(ctxt.wd.src, buff, nbytes)

    if ctxt.wd.typ == :io
       close(ctxt.wd.src)
    end

    ctxt.resp.bytes_recd = ctxt.resp.bytes_recd + nbytes

    nbytes::Csize_t
end

c_write_file_cb = cfunction(write_file_cb, Csize_t, (Ptr{Uint8}, Csize_t, Csize_t, Ptr{Void}))

function write_command_cb(buff::Ptr{Uint8}, sz::Csize_t, n::Csize_t, p_ctxt::Ptr{Void})
    # println("@write_command_cb")
    ctxt = unsafe_pointer_to_objref(p_ctxt)
    nbytes = sz * n

    write(ctxt.resp.body, buff, nbytes)
    ctxt.resp.bytes_recd = ctxt.resp.bytes_recd + nbytes

    nbytes::Csize_t
end

c_write_command_cb = cfunction(write_command_cb, Csize_t, (Ptr{Uint8}, Csize_t, Csize_t, Ptr{Void}))

function header_command_cb(buff::Ptr{Uint8}, sz::Csize_t, n::Csize_t, p_ctxt::Ptr{Void})
    # println("@header_cb")
    ctxt = unsafe_pointer_to_objref(p_ctxt)
    hdrlines = split(bytestring(buff, convert(Int, sz * n)), "\r\n")

    append!(ctxt.resp.headers, hdrlines)
    (sz*n)::Csize_t
end

c_header_command_cb = cfunction(header_command_cb, Csize_t, (Ptr{Uint8}, Csize_t, Csize_t, Ptr{Void}))

function curl_read_cb(out::Ptr{Void}, s::Csize_t, n::Csize_t, p_ctxt::Ptr{Void})
    # println("@curl_read_cb")
    ctxt = unsafe_pointer_to_objref(p_ctxt)
    bavail::Csize_t = s * n
    breq::Csize_t = ctxt.rd.sz - ctxt.rd.offset
    b2copy = bavail > breq ? breq : bavail

    if (ctxt.rd.typ == :buffer)
        ccall(:memcpy, Ptr{Void}, (Ptr{Void}, Ptr{Void}, Uint),
                out, convert(Ptr{Uint8}, pointer(ctxt.rd.str)) + ctxt.rd.offset, b2copy)
    elseif (ctxt.rd.typ == :io)
        b_read = read(ctxt.rd.src, Uint8, b2copy)
        ccall(:memcpy, Ptr{Void}, (Ptr{Void}, Ptr{Void}, Uint), out, b_read, b2copy)
    end
    ctxt.rd.offset = ctxt.rd.offset + b2copy

    r = convert(Csize_t, b2copy)
    r::Csize_t
end

c_curl_read_cb = cfunction(curl_read_cb, Csize_t, (Ptr{Void}, Csize_t, Csize_t, Ptr{Void}))


##############################
# Utility functions
##############################

macro ce_curl (f, args...)
    quote
        cc = CURLE_OK
        cc = $(esc(f))(ctxt.curl, $(args...))

        if(cc != CURLE_OK && cc != CURLE_FTP_COULDNT_RETR_FILE)
            error (string($f) * "() failed: error $cc, " * bytestring(curl_easy_strerror(cc)))
        end
    end
end

null_cb(curl) = return nothing

function set_opt_blocking(options::RequestOptions)
        o2 = deepcopy(options)
        o2.blocking = true
        return o2
end

function setup_easy_handle(url, options::RequestOptions)
    ctxt = ConnContext(options)

    curl = curl_easy_init()
    if (curl == C_NULL) throw("curl_easy_init() failed") end

    ctxt.curl = curl

    p_ctxt = pointer_from_objref(ctxt)

    if (options.implicit)
        url = "ftps://" * String(url) * "/"
    else
        url = "ftp://"* String(url) * "/"
    end

    ctxt.url = url

    @ce_curl curl_easy_setopt CURLOPT_URL url
    # @ce_curl curl_easy_setopt CURLOPT_VERBOSE Int64(1)

    if (~isempty(options.username) && ~isempty(options.passwd))
        @ce_curl curl_easy_setopt  CURLOPT_USERNAME options.username
        @ce_curl curl_easy_setopt  CURLOPT_PASSWORD options.passwd
    end

    if (options.ssl)
        @ce_curl curl_easy_setopt CURLOPT_USE_SSL CURLUSESSL_ALL
        @ce_curl curl_easy_setopt CURLOPT_SSL_VERIFYHOST Int64(2)
        @ce_curl curl_easy_setopt CURLOPT_SSLVERSION Int64(0)
        @ce_curl curl_easy_setopt CURLOPT_FTPSSLAUTH CURLFTPAUTH_SSL

        if (~options.verify_peer)
            @ce_curl curl_easy_setopt CURLOPT_SSL_VERIFYPEER Int64(0)
        else
            @ce_curl curl_easy_setopt CURLOPT_SSL_VERIFYPEER Int64(1)
        end
    end

    if (options.active_mode)
        @ce_curl curl_easy_setopt CURLOPT_FTPPORT "-"
    end

    return ctxt
end

function cleanup_easy_context(ctxt::Union(ConnContext,Bool))
    if isa(ctxt, ConnContext)
        if (ctxt.curl != C_NULL)
            curl_easy_cleanup(ctxt.curl)
            ctxt.curl = C_NULL
        end

        if ctxt.close_ostream
            close(ctxt.resp.body)
            ctxt.resp.body = nothing
            ctxt.close_ostream = false
        end
    end
end

function process_response(ctxt)
    resp_code = Array(Int,1)
    @ce_curl curl_easy_getinfo CURLINFO_RESPONSE_CODE resp_code

    total_time = Array(Float64,1)
    @ce_curl curl_easy_getinfo CURLINFO_TOTAL_TIME total_time

    ctxt.resp.code = resp_code[1]
    ctxt.resp.total_time = total_time[1]
end


##############################
# Library initializations
##############################

@doc """
    Global libcurl initialisation
""" ->
ftp_init() = curl_global_init(CURL_GLOBAL_ALL)

@doc """
    Global libcurl cleanup
""" ->
ftp_cleanup() = curl_global_cleanup()


##############################
# GET
##############################

@doc """
    Download file with non-persistent connection.

    - url: FTP server, ex "localhost"
    - file_name: name of file to download
    - options: options for connection, ex use ssl, implicit security, etc.

    returns resp::Response
""" ->
function ftp_get(url::String, file_name::String, options::RequestOptions=RequestOptions())
    if (options.blocking)
        ctxt = false
        try
            ctxt = setup_easy_handle(url, options)
            ctxt = ftp_get(ctxt, file_name)

            return ctxt.resp

        finally
            cleanup_easy_context(ctxt)
        end
    else
        return remotecall(myid(), get, url, set_opt_blocking(options))
    end
end

@doc """
    Download file with persistent connection.

    - ctxt: open connection to FTP server
    - file_name: name of file to download

    returns ctxt::ConnContext
""" ->
function ftp_get(ctxt::ConnContext, file_name::String)
    if (ctxt.options.blocking)
        try
            wd = WriteData()
            wd.typ = :io
            wd.name = file_name

            ctxt.wd = wd

            p_ctxt = pointer_from_objref(ctxt)

            command = "RETR " * file_name
            @ce_curl curl_easy_setopt CURLOPT_CUSTOMREQUEST command
            @ce_curl curl_easy_setopt CURLOPT_WRITEFUNCTION c_write_file_cb
            @ce_curl curl_easy_setopt CURLOPT_WRITEDATA p_ctxt

            @ce_curl curl_easy_perform
            process_response(ctxt)

            return ctxt

        catch e
            cleanup_easy_context(ctxt)
            throw(e)
        end
    else
        return remotecall(myid(), get, url, set_opt_blocking(options))
    end
end


##############################
# PUT
##############################

@doc """
    Upload file with non-persistent connection.

    - url: FTP server, ex "localhost"
    - ctxt: open connection to FTP server
    - file_name: name of file to upload
    - file: the file to upload
    - options: options for connection, ex use ssl, implicit security, etc.

    returns resp::Response
""" ->
function ftp_put(url::String, file_name::String, file::IO, options::RequestOptions=RequestOptions())
    if (options.blocking)
        ctxt = false
        try

            ctxt = setup_easy_handle(url, options)
            ctxt = ftp_put(ctxt, file_name, file)

            return ctxt.resp

        finally
            cleanup_easy_context(ctxt)
        end
    else
        return remotecall(myid(), put, url, set_opt_blocking(options))
    end
end

@doc """
    Upload file with persistent connection.

    - ctxt: open connection to FTP server
    - file_name: name of file to upload
    - file: the file to upload

    returns ctxt::ConnContext
""" ->
function ftp_put(ctxt::ConnContext, file_name::String, file::IO)
    if (ctxt.options.blocking)
        try
            rd = ReadData()
            rd.typ = :io
            rd.src = file
            seekend(file)
            rd.sz = position(file)
            seekstart(file)

            ctxt.rd = rd

            p_ctxt = pointer_from_objref(ctxt)

            command = "STOR " * file_name
            @ce_curl curl_easy_setopt CURLOPT_URL ctxt.url*file_name
            @ce_curl curl_easy_setopt CURLOPT_CUSTOMREQUEST command
            @ce_curl curl_easy_setopt CURLOPT_UPLOAD Int64(1)
            @ce_curl curl_easy_setopt CURLOPT_READDATA p_ctxt
            @ce_curl curl_easy_setopt CURLOPT_READFUNCTION c_curl_read_cb

            @ce_curl curl_easy_perform
            process_response(ctxt)

            return ctxt

        catch e
            cleanup_easy_context(ctxt)
            throw(e)
        end
    else
        return remotecall(myid(), get, url, set_opt_blocking(options))
    end
end


##############################
# COMMAND
##############################

@doc """
    Pass FTP command with non-persistent connection.

    - url: FTP server, ex "localhost"
    - cmd: FTP command to execute
    - options: options for connection, ex use ssl, implicit security, etc.

    returns resp::Response
""" ->
function ftp_command(url::String, cmd::String, options::RequestOptions=RequestOptions())
    if (options.blocking)
        ctxt = false
        try
            ctxt = setup_easy_handle(url, options)
            ctxt = ftp_command(ctxt, cmd)

            return ctxt.resp

        finally
            cleanup_easy_context(ctxt)
        end
    else
        # Todo: figure out non-blocking
    end
end

@doc """
    Pass FTP command with persistent connection.

    - ctxt: open connection to FTP server
    - cmd: FTP command to execute

    returns ctxt::ConnContext
""" ->
function ftp_command(ctxt::ConnContext, cmd::String)
    if (ctxt.options.blocking)
        try
            p_ctxt = pointer_from_objref(ctxt)

            @ce_curl curl_easy_setopt CURLOPT_WRITEFUNCTION c_write_command_cb
            @ce_curl curl_easy_setopt CURLOPT_WRITEDATA p_ctxt
            @ce_curl curl_easy_setopt CURLOPT_HEADERFUNCTION c_header_command_cb
            @ce_curl curl_easy_setopt CURLOPT_HEADERDATA p_ctxt

            @ce_curl curl_easy_setopt CURLOPT_CUSTOMREQUEST cmd

            @ce_curl curl_easy_perform
            process_response(ctxt)

            cmd = split(cmd)
            if (ctxt.resp.code == 250 && cmd[1] == "CWD")
                ctxt.url *= cmd[2]
            end

            return ctxt

        catch e
            cleanup_easy_context(ctxt)
            throw(e)
        end
    else

    end
end


##############################
# CONNECT
##############################

@doc """
    Establish connection to FTP server.

    - url: FTP server, ex "localhost"
    - options: options for connection, ex use ssl, implicit security, etc.

    returns ctxt::ConnContext
""" ->
function ftp_connect(url::String, options::RequestOptions=RequestOptions())
    if (options.blocking)
        ctxt = false
        try
            ctxt = setup_easy_handle(url, options)

            @ce_curl curl_easy_perform
            process_response(ctxt)

            return ctxt

        catch e
            cleanup_easy_context(ctxt)
            throw(e)
        end
    else
        # Todo: figure out non-blocking
    end
end


##############################
# CLOSE
##############################

@doc """
    Close connection FTP server.

    - ctxt: connection to clean up
""" ->
function ftp_close_connection(ctxt::ConnContext)
    cleanup_easy_context(ctxt)
end

end #module


