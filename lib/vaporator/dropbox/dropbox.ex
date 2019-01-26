defmodule Vaporator.Dropbox do
  use Timex
  require Logger
  @moduledoc """
  REST API Interface with Dropbox

  TODO:

  - Better, more descriptive error messaging/routing
  """

  @enforce_keys [:access_token]
  defstruct [:access_token]

  @api_url Application.get_env(:vaporator, :api_url)
  @content_url Application.get_env(:vaporator, :content_url)

  def json_headers do
    %{"Content-Type" => "application/json"}
  end

  # def auth_headers(auth) do
  #   %{"Authorization" => "Bearer #{auth.access_token}"}
  # end

  def auth_headers(dbx) do
    %{"Authorization" => "Bearer #{dbx.access_token}"}
  end

  def post_api(dbx, url_path, body \\ %{}) do
    case Poison.encode(body) do
      {:ok, encoded_body} ->
        post_request(
          dbx, "#{@api_url}#{url_path}", encoded_body,
          json_headers()
        )
      {:error, error} ->
        Logger.error("Error in Poison encoding: {#error}")
        {:error, {:bad_encode, error}}
    end
  end

  @doc """
  Prepare file upload POST requests

  Args:

  - dbx (Vaporator.Dropbox): Dropbox client
  - url_path (binary): URL path to be added to @content_url base URL
  - local_path (binary): Local file system path
  - api_args (Map): Dropbox API file transfer arguments to be
      associated with "Dropbox-API-Arg" header key
  - headers (Map): Additional headers. Will default to Content-Type =>
      octet-stream for normal file uploads.

  """
  def post_upload(dbx, url_path, local_path, api_args \\ %{}, headers \\ %{}) do
    post_file_transfer(
      dbx, url_path, {:file, local_path}, api_args,
      Map.merge(%{"Content-Type" => "application/octet-stream"}, headers)
    )
  end

  @doc """
  Prepare file download POST requests

  Args:

  - dbx (Vaporator.Dropbox): Dropbox client
  - url_path (binary): URL path to be added to @content_url base URL
  - data (Map): POST body data
  - api_args (Map): Dropbox API file transfer arguments to be
      associated with "Dropbox-API-Arg" header key
  - headers (Map): Additional headers. Will default to Content-Type =>
      octet-stream for normal file uploads.

  """
  def post_download(
    dbx, url_path, data \\ [], api_args \\ %{}, headers \\ %{}
  ) do
    post_file_transfer(
      dbx, url_path, data, headers, api_args,
      &process_download_response/1 # Downloads need to be processed
                                   # differently
    )
  end

  @doc """
  Prepare file-content-related POST requests

  The /2 and /3 exist because uploads use the default response
  processor (process_json_response), and downloads require a download
  response processor (process_download_response).

  File transfers are different from normal API requests, in that they
  have a set of `Dropbox-API-Arg` arguments that must be added to the
  header, as well has needing to use the @content_url base URL.

  TODO: Implement/integrate automagical pagination, perhaps through
  some sort of lazily-loaded sequence generator.
  
  """
  def post_file_transfer(dbx, url_path, body, api_args, headers) do
    post_file_transfer(
      dbx, url_path, body, api_args, headers, &process_json_response/1
    )
  end
  def post_file_transfer(dbx, url_path, body, api_args, headers, processor) do
    case Poison.encode(api_args) do
      {:ok, encoded} ->
        post_request(
          dbx,
          "#{@content_url}#{url_path}", # Needs @content_url
          body,                   
          Map.merge(               # API header keys
            %{"Dropbox-API-Arg": encoded},
            headers             # e.g. Content-Type => octet for
                                # uploads
          ),
          processor             # default: process_json_response
        )
      {:error, error} ->
        Logger.error("Error in Poison encoding")
        {:error, error}
    end
  end

  @doc """
  Prepare general POST requests

  This is the last stop for all API POSTs (both purely API and
  file-transfer-related). It does only two things:

  - Augments the given headers with token authentication
  - Sends the data to HTTPoison.post and processes it with a provided
    `processor` function
  
  """
  def post_request(dbx, url, body, headers) do
    post_request(dbx, url, body, headers, &process_json_response/1)
  end
  def post_request(dbx, url, body, headers, processor) do
    headers = Map.merge(headers, auth_headers(dbx))
    case HTTPoison.post(url, body, headers) do
      {:ok, response} -> processor.(response)
      {:error, reason} ->
        Logger.error("Error with HTTPoison POST: #{reason}")
        {:error, reason}
    end
  end

  def process_bad_response(%HTTPoison.Response{status_code: status_code,
                                                    body: body}) do
    case {status_code, JSON.decode(body)} do
      # File not found
      {409, {:ok, %{"error_summary" => summary,
                    "error" => %{".tag" => "path",
                                 "path" => %{".tag" => "not_found"}}}}}
        -> {:error, {:path_not_found, summary}}
      {409, {:ok, %{"error_summary" => summary,
                    "error" => %{".tag" => "path_lookup",
                                 "path_lookup" => %{".tag" => "not_found"}}}}}
        -> {:error, {:path_not_found, summary}}
      # Something else API-related happened
      {status_code, {:ok, body}} when status_code in 400..599 ->
        {:error, {:bad_status,
                  {:status_code, status_code}, body}}
      # No idea
      _ ->
        {:error, {:unhandled_status, {:status_code, status_code}, body}}
    end
  end

  @doc """
  Process a JSON response from the REST API

  - Decodes and returns body (as Map) if status code is 200 and body
    decodes correctly
  
  - Returns the following error "signals"
      - :bad_decode for problems decoding JSON body
      - :bad_status for status codes >= 400 and <= 599
      - :unhandled_status for any other status code
  """
  def process_json_response(%HTTPoison.Response{status_code: 200,
                                                body: body}) do
    case Poison.decode(body) do
      {:ok, term} -> {:ok, term}
      {:error, error} -> {:error, {:bad_decode, error}}
    end
  end
  def process_json_response(response) do
    process_bad_response(response)
  end

  @doc """
  Process a binary response from the REST API for downloaded files

  - Decodes and returns body binary content and headers (as
    Vaporator.CloudFs.FileContent) if status code is 200
  
  - Returns the following error "signals"
      - :bad_status for status codes >= 400 and <= 599
      - :unhandled_status for any other status code
  """
  def process_download_response(%HTTPoison.Response{status_code: 200,
                                                    body: body,
                                                    headers: headers}) do
    {:ok, %Vaporator.CloudFs.FileContent{content: body, headers: headers}}
  end    
  def process_download_response(response) do
    process_bad_response(response)
  end

  @doc """
  Convert a Dropbox file/folder metadata element into a
  Vaporator.CloudFs.Meta element
  """
  def dropbox_meta_to_cloudfs(meta) do
    %Vaporator.CloudFs.Meta{
      meta: meta,
      type: meta |> Map.get(".tag", "none") |> String.to_atom,
      name: meta["name"],
      path: meta["path_display"],
      modify_time: Timex.parse(meta["server_modified"], "{ISO:Extended}"),
    }
  end

  @doc """
  Prepares/transforms a Dropbox path
  """
  def prep_path("/"), do: ""
  def prep_path(path), do: path

  @doc """
  Is the dbx_path a directory to place the local_path, or is it an
  absolute path name for the file?

  This currently only returns true if the dbx_path ends in a /

  """
  def dbx_path_is_dir?(_local_path, dbx_path) do
    String.ends_with?(dbx_path, ["/"])
  end

  @doc """
  Prepare dbx_path for upload, given a local_path.

  If the dbx_path is a directory, then add the local_path's file name
  (i.e. basename) to the end of dbx_path. Otherwise, leave the
  dbx_path as is.
  """
  def prep_dbx_path(local_path, dbx_path) do
    if dbx_path_is_dir?(local_path, dbx_path) do
      Path.join(dbx_path, Path.basename(local_path))
    else
      dbx_path
    end
  end

  @doc """
  Get the metadata for the Dropbox file at path
  
  """
  def get_metadata(dbx, path, args \\ %{}) do
    body = Map.merge(%{:path => prep_path(path)}, args)
    case post_api(dbx, "/files/get_metadata", body) do
      {:ok, meta} -> {:ok, dropbox_meta_to_cloudfs(meta)}
      {:error, error} -> {:error, error}
    end
  end

  def list_folder(dbx, path, args \\ %{}) do
    body = Map.merge(%{:path => prep_path(path)}, args)
    case post_api(dbx, "/files/list_folder", body) do
      {:ok, result_meta=%{"entries" => entries}} when entries != [] ->
        results = for meta <- entries do
            dropbox_meta_to_cloudfs(meta)
          end
        {:ok, %Vaporator.CloudFs.ResultsMeta{results: results,
                                             meta: result_meta}}
      {:ok, _} ->
        Logger.error("No entries listed in response object")
        {:error, {:no_entries, "No entries listed in response object"}}
      {:error, error} ->
        {:error, error}
    end
  end

  def file_download(dbx, path, dbx_api_args \\ %{}) do
    post_download(dbx, "files/download", [], dbx_api_args, %{:path => path})
  end

  def file_upload(dbx, local_path, dbx_path, args \\ %{}) do
    case post_upload(
          dbx, "files/upload", local_path,
          Map.merge(%{:path => prep_dbx_path(local_path, dbx_path),
                      :mode => "overwrite",
                      :autorename => true,
                      :mute => false}, args),
          %{}
        ) do
      {:ok, meta} -> {:ok, dropbox_meta_to_cloudfs(meta)}
      {:error, error} -> {:error, error}
    end
  end

  @chunk_size 4 * :math.pow(2, 20) |> floor

  def sha256(s) do
    :crypto.hash(:sha256, s)
  end

  @doc """
  Calculate the Dropbox content hash of local file. This function
  *assumes* that the given path exists and can be streamed.
  """
  def dbx_hash!(path) do
    File.stream!(path, [], @chunk_size)
    |> Enum.map(&sha256/1)
    |> Enum.join
    |> sha256
    |> Base.encode16
    |> String.downcase
  end

  @doc """
  Does the file represented by dbx_meta have the same content as the
  file at local_path?
  
  """
  def same_content?(local_path, cfs_meta) do
    dbx_hash!(local_path) == cfs_meta.meta["content_hash"]
  end

  @doc """
  Need to be able to update binary content of a file on the cloud
  file system to the version on the local file system.
  
  In the case of file_upload, the file is always transferred. In the
  case of file_update, the file transfer only happens if the cloud
  content is different from the local content.
  
  Args:
  - fs (Vaporator.CloudFs impl): Cloud file system
  - local_path (binary): Path of file on local file system to upload
  - dbx_path (binary): Path on cloud file system to place uploaded
      content. If this path ends with a "/" then it should be
      treated as a directory in which to place the local_path
  - args (Map): File-system-specific arguments to pass to the
      underlying subsystem. 
  
  Returns:
    {:ok, Vaporator.CloudFs.FileContent}
      or
    {:error, {:bad_decode, decode error (any)}
      or 
    {:error, {:bad_status, {:status_code, code (int)}, JSON (Map)}}
      or 
    {:error, {:unhandled_status, {:status_code, code (int)}, body (binary)}}
  """
  def file_update(dbx, local_path, dbx_path, args \\ %{}) do
    case get_metadata(dbx, dbx_path) do
      {:ok, cfs_meta} ->
        if not same_content?(local_path, cfs_meta) do
          file_upload(dbx, local_path, dbx_path, args)
        else
          {:ok, cfs_meta}
        end
      {:error, {:path_not_found, _}} ->
        file_upload(dbx, local_path, dbx_path, args)
      {:error, error} -> {:error, error}
    end
  end

  def file_remove(dbx, path, args \\ %{}) do
    case post_api(
          dbx, "/files/delete_v2",
          Map.merge(%{"path" => path}, args)) do
      {:ok, %{"metadata" => meta}} -> {:ok, dropbox_meta_to_cloudfs(meta)}
      {:error, error} -> {:error, error}
    end
  end

  def folder_remove(dbx, path, args \\ %{}) do
    file_remove(dbx, path, args)
  end

  def sync_files(
    dbx, local_path, dbx_path, file_regex, folder_regex, args \\ %{}
  ) do
    case DirWalker.start_link(local_path, [include_stat: true,
                                           include_dir_names: true]) do
      {:ok, walker} -> true
    end
  end
end

defimpl Vaporator.CloudFs, for: Vaporator.Dropbox do
  require Logger

  def list_folder(dbx, path, args \\ %{}) do
    Vaporator.Dropbox.list_folder(dbx, path, args)
  end

  def get_metadata(dbx, path, args \\ %{}) do
    Vaporator.Dropbox.get_metadata(dbx, path, args)
  end
  
  # def list_folder(dbx, path, args \\ %{}) do
  #   body = Map.merge(%{:path => prep_path(path)}, args)
  #   case post_api(dbx, "/files/list_folder", body) do
  #     {:ok, result_meta=%{"entries" => entries}} when entries != [] ->
  #       results = for meta <- entries do
  #           dropbox_meta_to_cloudfs(meta)
  #         end
  #       {:ok, %Vaporator.CloudFs.ResultsMeta{results: results,
  #                                            meta: result_meta}}
  #     {:ok, _} ->
  #       Logger.error("No entries listed in response object")
  #       {:error, {:no_entries, "No entries listed in response object"}}
  #     {:error, error} ->
  #       {:error, error}
  #   end
  # end

  # def get_metadata(dbx, path, args \\ %{}) do
    
  #   body = Map.merge(%{:path => prep_path(path)}, args)
  #   case post_api(dbx, "/files/get_metadata", body) do
  #     {:ok, meta} -> dropbox_meta_to_cloudfs(meta)
  #     {:error, error} -> {:error, error}
  #   end
  # end

  def file_download(dbx, path, dbx_api_args \\ %{}) do
    Vaporator.Dropbox.file_download(dbx, path, dbx_api_args)
    # post_download(dbx, "files/download", [], dbx_api_args, %{:path => path})
  end

  def file_upload(dbx, local_path, dbx_path, args \\ %{}) do
    Vaporator.Dropbox.file_upload(dbx, local_path, dbx_path, args)
    # case post_upload(
    #       dbx, "files/upload", local_path,
    #       Map.merge(%{:path => prep_dbx_path(local_path, dbx_path),
    #                   :mode => "overwrite",
    #                   :autorename => true,
    #                   :mute => false}, args),
    #       %{}
    #     ) do
    #   {:ok, meta} -> {:ok, dropbox_meta_to_cloudfs(meta)}
    #   {:error, error} -> {:error, error}
    # end
  end

  def file_update(dbx, local_path, dbx_path, args \\ %{}) do
    Vaporator.Dropbox.file_update(dbx, local_path, dbx_path, args)
  end

  def file_remove(dbx, path, args \\ %{}) do
    Vaporator.Dropbox.file_remove(dbx, path, args)
    # case post_api(
    #       dbx, "/files/delete_v2",
    #       Map.merge(%{"path" => path}, args)) do
    #   {:ok, %{"metadata" => meta}} -> {:ok, dropbox_meta_to_cloudfs(meta)}
    #   {:error, error} -> {:error, error}
    # end
  end
  def folder_remove(dbx, path, args \\ %{}), do: file_remove(dbx, path, args)

  def sync_files(
    dbx, local_path, dbx_path, file_regex, folder_regex, args \\ %{}
  ) do
    Vaporator.Dropbox.sync_files(
      dbx, local_path, dbx_path, file_regex, folder_regex, args
    )
  end

  # # copy
  # body = %{"from_path" => from_path, "to_path" => to_path}
  # result = to_string(Poison.Encoder.encode(body, []))
  # post(client, "/files/copy_v2", result)
  # # move
  # body = %{"from_path" => from_path, "to_path" => to_path}
  # result = to_string(Poison.Encoder.encode(body, []))
  # post(client, "/files/move", result)
  # # delete (file or folder)
  # body = %{"path" => path}
  # result = to_string(Poison.Encoder.encode(body, []))
  # post(client, "/files/delete_v2", result)

end
