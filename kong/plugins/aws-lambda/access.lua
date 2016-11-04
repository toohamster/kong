local aws_v4 = require "kong.plugins.aws-lambda.v4"
local responses = require "kong.tools.responses"
local utils = require "kong.tools.utils"
local Multipart = require "multipart"
local http = require "resty.http"
local cjson = require "cjson"

local string_find = string.find
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_read_body = ngx.req.read_body
local ngx_req_get_post_args = ngx.req.get_post_args
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_req_get_body_data = ngx.req.get_body_data

local CONTENT_TYPE = "content-type"

local _M = {}

local function retrieve_parameters()
  ngx_req_read_body()
  local body_parameters
  local content_type = ngx_req_get_headers()[CONTENT_TYPE]
  if content_type and string_find(content_type:lower(), "multipart/form-data", nil, true) then
    body_parameters = Multipart(ngx_req_get_body_data(), content_type):get_all()
  elseif content_type and string_find(content_type:lower(), "application/json", nil, true) then
    body_parameters = cjson.decode(ngx_req_get_body_data())
  else
    body_parameters = ngx_req_get_post_args()
  end

  return utils.table_merge(ngx_req_get_uri_args(), body_parameters)
end

function _M.execute(conf)
  local bodyJson = cjson.encode(retrieve_parameters())

  local host = string.format("lambda.%s.amazonaws.com", conf.aws_region)
  local path = string.format("/2015-03-31/functions/%s/invocations", 
                            conf.function_name)

  local opts = {
    region = conf.aws_region,
    service = "lambda",
    method = "POST",
    headers = {
      ["X-Amz-Target"] = "invoke",
      ["X-Amz-Invocation-Type"] = conf.invocation_type,
      ["X-Amx-Log-Type"] = conf.log_type,
      ["Content-Type"] = "application/x-amz-json-1.1",
      ["Content-Length"] = tostring(string.len(bodyJson))
    },
    body = bodyJson, 
    path = path,
    access_key = conf.aws_key,
    secret_key = conf.aws_secret,
    query = conf.qualifier and "Qualifier="..conf.qualifier
  }

  local request, err = aws_v4(opts)
  if err then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  -- Trigger request
  local client = http.new()
  client:connect(host, 443)
  client:set_timeout(60000)
  local ok, err = client:ssl_handshake()
  if not ok then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  local res, err = client:request {
    method = "POST",
    path = request.url,
    body = request.body,
    headers = request.headers
  }
  if not res then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  local status = res.status
  local body = res:read_body()
  local headers = res.headers

  local ok, err = client:set_keepalive(conf.keepalive)
  if not ok then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  -- Send response to client
  for k, v in pairs(headers) do
    ngx.header[k] = v
  end
  responses.send(status, body, headers, true)
end

return _M
