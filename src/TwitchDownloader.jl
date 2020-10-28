#=
TwitchDownloader:
- Julia version: 1.5.2
- Author: imalento =#
module TwitchDownloader
using IniFile
using ArgParse
using HTTP
using JSON

function hms_to_sec(hms::String)::Int
    tokens = split(hms, ":")
    rate = 1
    total = 0
    for part in reverse(tokens)
        total += parse(Int, part) * rate
        rate = rate * 60
    end
    return total
end

function find_video_name_and_domain(video_dict::Dict)::Tuple{String,String}
    thumbnail_url = video_dict["data"][1]["thumbnail_url"]
    tokens = split(thumbnail_url, "/")
    return tokens[6], "https://$(tokens[5]).cloudfront.net/"
end

function get_access_token(client_id, client_secret)
    params = Dict("client_id" => client_id,
                  "client_secret" => client_secret,
                  "grant_type" => "client_credentials",
                  "scope" => "analytics:read:games")
    res = HTTP.post("https://id.twitch.tv/oauth2/token", body = HTTP.Form(params))
    return JSON.parse(String(res.body))["access_token"]
end

function get_video_dict(client_id, access_token, video_id)
    params = Dict("id" => video_id)
    res = HTTP.get("https://api.twitch.tv/helix/videos",
        ["Client-ID" => client_id, "Authorization" => "Bearer $(access_token)"],
        query = params)
    return JSON.parse(String(res.body))
end

function fetch_playlist(video_name, domain)
    prefixes = ("https://vod-secure.twitch.tv/", domain)
    suffixes = ("/chunked/index-dvr.m3u8", "/720p60/index-dvr.m3u8")

    combinations = collect(Iterators.product(prefixes, suffixes))
    for (prefix, suffix) in combinations
        playlist_url = prefix * video_name * suffix
        println(playlist_url)
        try
            res = HTTP.get(playlist_url)
            if res.status == 200
                return String(res.body)
            else
                continue
            end
        catch
            continue
        end
    end

    return nothing
end

function get_segments(playlist::String, begin_sec, end_sec)
    parts = split(playlist, "\n")
    time = 0.0::Float64
    segments = []
    for part in parts
        if startswith(part, "#EXTINF")
            time += parse(Float64, part[9:length(part) - 1])
            continue
        end
        if startswith(part, "#") || length(part) == 0
            continue
        end
        if (begin_sec === nothing || begin_sec <= floor(time)) && (end_sec === nothing || floor(time) <= end_sec)
            push!(segments, part)
        end
    end
    return segments
end

function parse_commandline()
    aps = ArgParse.ArgParseSettings()
    @ArgParse.add_arg_table aps begin
        "--begin"
            help = "HH:MM:SS begin time"
        "--end"
            help = "HH:MM:SS end time"
        "video_id"
            required = true
    end
    return ArgParse.parse_args(aps)
end

function main()
    args_dict = parse_commandline()
    video_id = args_dict["video_id"]
    ini = read(IniFile.Inifile(), "config.ini")

    out_dir = get(ini, "DEFAULT", "out_dir")
    client_id = get(ini, "Twitch", "client_id")
    client_secret = get(ini, "Twitch", "client_secret")
    ts_file = joinpath(out_dir, "$(video_id).ts")
    mp4_file = joinpath(out_dir, "$(video_id).ts.mp4")
    dat_file = joinpath(out_dir, "$(video_id).dat")
    if (isfile(ts_file) || isfile(mp4_file) || isfile(dat_file))
        println("Already exists.")
        return
    end

    begin_sec = nothing
    if (args_dict["begin"] !== nothing)
        begin_sec = hms_to_sec(args_dict["begin"])
    end

    end_sec = nothing
    if (args_dict["end"] !== nothing)
        end_sec = hms_to_sec(args_dict["end"])
    end

    access_token = get_access_token(client_id, client_secret)

    video_dict = get_video_dict(client_id, access_token, video_id)
    video_name, domain = find_video_name_and_domain(video_dict)
    playlist = fetch_playlist(video_name, domain)
    segments = get_segments(playlist, begin_sec, end_sec)

    all_num = length(segments)
    println("$all_num Segments")
    progress = 0

    open(ts_file, "a") do f
       for segment in segments
           if (contains(segment, "-unmuted"))
               segment = replace(segment, "-unmuted" => "-muted", count = 1)
           end
           fetch_url = domain * video_name * "/chunked/" * segment
           println(fetch_url)
           while true
               try
                   res = HTTP.get(fetch_url; retry = false, readtimeout = 60)
                   write(f, res.body)
                break
               catch
                   # sleep
                   println("download error")
                   sleep(30)
                   continue
                   # return
               end
           end
           progress += 1
           if mod(progress, 10) == 0
               println("Downloaded $(progress) / $(all_num)")
           end
       end
    end
    println("Download Complete.")
    touch(dat_file)
end

Base.@ccallable function julia_main()::Cint
    try
        main()
    catch
        Base.invokelatest(Base.display_error, Base.catch_stack())
        return 1
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module
