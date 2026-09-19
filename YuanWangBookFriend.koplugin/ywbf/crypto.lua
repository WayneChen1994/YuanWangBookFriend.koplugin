--[[--
API Key 加密存储（PRD F8.4：密钥不以明文落盘）。

实现：AES-256-ECB（PKCS7 填充），密钥由设备唯一信息经 PBKDF2-HMAC-SHA1 派生；
加密侧 EVP 函数由本模块自行声明（KOReader 的 ffi/crypto 只暴露了解密）。
若 libcrypto 不可用，降级为 PBKDF2/XOR 混淆（仍不明文，但强度较低），保证功能不中断。
--]]--

local Crypto = {}

local ok_ffi, ffi = pcall(require, "ffi")
local libcrypto, kcrypto = nil, nil
local has_aes = false
local has_pbkdf2 = false

-- LuaJIT 是 Lua 5.1 语义，没有 5.2 的位运算符，必须用 bit 库
local ok_bit, bit = pcall(require, "bit")

local function bxor(a, b)
    if ok_bit and bit and bit.bxor then return bit.bxor(a, b) end
    local r, p = 0, 1
    for _ = 1, 8 do
        local ab, bb = a % 2, b % 2
        if ab ~= bb then r = r + p end
        a = (a - ab) / 2
        b = (b - bb) / 2
        p = p * 2
    end
    return r
end

local function try_cdef(decl)
    pcall(ffi.cdef, decl)  -- 若已声明且一致，LuaJIT 会忽略重复定义
end

function Crypto:init()
    if not ok_ffi then
        return false, "ffi unavailable"
    end
    local ok = pcall(function()
        require("ffi/loadlib")
        require("ffi/crypto_h")
        libcrypto = ffi.loadlib("crypto", "57")
        kcrypto = require("ffi/crypto")
    end)
    if not ok or not libcrypto then
        return false, "libcrypto unavailable"
    end

    try_cdef[[
int EVP_EncryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
int EVP_EncryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *, int);
]]
    has_aes = (libcrypto.EVP_aes_256_ecb ~= nil)
    has_pbkdf2 = (kcrypto and kcrypto.pbkdf2_hmac_sha1 ~= nil)
    return true, has_aes and "aes-256-ecb" or "xor-fallback"
end

-- ---------- 设备盐值 ----------

local SALT_SOURCES = {
    "/proc/usid",                       -- Kindle 序列号
    "/sys/class/net/wlan0/address",     -- 无线 MAC
    "/sys/class/net/eth0/address",
    "/proc/cpuinfo",
}

local function first_nonempty_line(path)
    local f = io.open(path, "r")
    if not f then return nil end
    for _ = 1, 20 do
        local line = f:read("*l")
        if not line then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then f:close(); return line end
    end
    f:close()
    return nil
end

function Crypto:deviceSalt()
    if self._salt then return self._salt end
    local parts = {}
    for _, path in ipairs(SALT_SOURCES) do
        local v = first_nonempty_line(path)
        if v then parts[#parts + 1] = v end
    end
    if #parts == 0 then
        -- 无可用硬件标识时退化为固定盐（安全性降级，但保证功能可用）
        parts[#parts + 1] = "ywbf-fallback-salt"
    end
    self._salt = table.concat(parts, "|")
    return self._salt
end

-- ---------- 编解码辅助 ----------

local function to_hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

local function from_hex(s)
    return (s:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end

Crypto.to_hex = to_hex
Crypto.from_hex = from_hex

local function pkcs7_pad(s, bs)
    local pad = bs - (#s % bs)
    if pad == 0 then pad = bs end
    return s .. string.rep(string.char(pad), pad)
end

-- ---------- 密钥派生 ----------

function Crypto:deriveKey()
    if has_pbkdf2 then
        local ok, key = pcall(kcrypto.pbkdf2_hmac_sha1, self:deviceSalt(), "ywbf-v1", 4096, 32)
        if ok and key and #key == 32 then return key end
    end
    -- 降级：自实现 FNV-1a 变体填充 32 字节
    local salt = self:deviceSalt()
    local out = {}
    for i = 1, 32 do
        local h = 2166136261 + i * 16777619
        for j = 1, #salt do
            h = bxor(h, string.byte(salt, j)) % 4294967296
            h = (h * 16777619) % 4294967296
        end
        out[i] = string.char(h % 256)
    end
    return table.concat(out)
end

-- ---------- AES-256-ECB ----------

function Crypto:aesEncrypt(plain, key)
    local bs = 16
    local data = pkcs7_pad(plain, bs)
    local ctx = libcrypto.EVP_CIPHER_CTX_new()
    if ctx == nil then return nil, "ctx alloc failed" end
    if libcrypto.EVP_EncryptInit_ex(ctx, libcrypto.EVP_aes_256_ecb(), nil, key, nil) ~= 1 then
        libcrypto.EVP_CIPHER_CTX_free(ctx)
        return nil, "encrypt init failed"
    end
    libcrypto.EVP_CIPHER_CTX_set_padding(ctx, 0)
    local out = ffi.new("char[?]", #data + bs)
    local outl = ffi.new("int[1]")
    if libcrypto.EVP_EncryptUpdate(ctx, out, outl, data, #data) ~= 1 then
        libcrypto.EVP_CIPHER_CTX_free(ctx)
        return nil, "encrypt update failed"
    end
    local total = outl[0]
    local finl = ffi.new("int[1]")
    if libcrypto.EVP_EncryptFinal_ex(ctx, out + total, finl) ~= 1 then
        libcrypto.EVP_CIPHER_CTX_free(ctx)
        return nil, "encrypt final failed"
    end
    total = total + finl[0]
    libcrypto.EVP_CIPHER_CTX_free(ctx)
    return ffi.string(out, total)
end

function Crypto:aesDecrypt(cipher, key)
    if not kcrypto then return nil, "crypto module unavailable" end
    local c = kcrypto.get_aes_ecb_cipher(32)
    if not c then return nil, "cipher unavailable" end
    local dec, declen = kcrypto.evp_decrypt(c, cipher, key, nil)
    if not dec then return nil, "decrypt failed" end
    return kcrypto.pkcs7_unpad(dec, declen, 16)
end

-- ---------- XOR 降级方案 ----------

local function xor_crypt(s, key)
    local out = {}
    local klen = #key
    for i = 1, #s do
        out[i] = string.char(bxor(string.byte(s, i), string.byte(key, ((i - 1) % klen) + 1)) % 256)
    end
    return table.concat(out)
end

-- ---------- 对外接口 ----------

-- 返回密文字符串；前缀标识算法版本，便于后续迁移
function Crypto:encrypt(plain)
    if plain == nil then return nil end
    local key = self:deriveKey()
    if has_aes and ok_ffi then
        local ok, cipher = pcall(self.aesEncrypt, self, plain, key)
        if ok and cipher then return "aes1:" .. to_hex(cipher) end
    end
    return "xor1:" .. to_hex(xor_crypt(plain, key))
end

function Crypto:decrypt(blob)
    if type(blob) ~= "string" or blob == "" then return nil end
    local algo, payload = blob:match("^(%a+%d+):([0-9a-fA-F]+)$")
    if not algo or not payload then return nil, "unknown blob format" end
    local cipher = from_hex(payload)
    local key = self:deriveKey()
    if algo == "aes1" then
        if not (has_aes and ok_ffi) then return nil, "aes unavailable on this device" end
        return self:aesDecrypt(cipher, key)
    elseif algo == "xor1" then
        return xor_crypt(cipher, key)
    end
    return nil, "unsupported algorithm: " .. tostring(algo)
end

return Crypto
