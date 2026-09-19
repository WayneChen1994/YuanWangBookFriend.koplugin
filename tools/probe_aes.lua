-- 探针 C：验证能否在 KPW4 上用 libcrypto 做 AES-256-ECB 加密（ffi/crypto 只提供解密）
package.path = "common/?.lua;frontend/?.lua;/mnt/us/koreader/common/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
require("ffi/loadlib")

local ffi = require("ffi")
require("ffi/crypto_h")
local libcrypto = ffi.loadlib("crypto", "57")
local crypto = require("ffi/crypto")

local ok_cdef, err_cdef = pcall(ffi.cdef, [[
int EVP_EncryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
int EVP_EncryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *, int);
]])
print("cdef encrypt funcs:", ok_cdef, ok_cdef and "" or tostring(err_cdef))
if not ok_cdef then os.exit(1) end

local function pkcs7_pad(s, bs)
    local pad = bs - (#s % bs)
    if pad == 0 then pad = bs end
    return s .. string.rep(string.char(pad), pad)
end

local function aes_256_ecb_encrypt(plain, key)
    assert(#key == 32, "key must be 32 bytes")
    local bs = 16
    local data = pkcs7_pad(plain, bs)
    local ctx = libcrypto.EVP_CIPHER_CTX_new()
    if ctx == nil then return nil, "ctx nil" end
    if libcrypto.EVP_EncryptInit_ex(ctx, libcrypto.EVP_aes_256_ecb(), nil, key, nil) ~= 1 then
        return nil, "init failed"
    end
    libcrypto.EVP_CIPHER_CTX_set_padding(ctx, 0)
    local out = ffi.new("char[?]", #data + bs)
    local outl = ffi.new("int[1]")
    if libcrypto.EVP_EncryptUpdate(ctx, out, outl, data, #data) ~= 1 then
        return nil, "update failed"
    end
    local total = outl[0]
    local finl = ffi.new("int[1]")
    if libcrypto.EVP_EncryptFinal_ex(ctx, out + total, finl) ~= 1 then
        return nil, "final failed"
    end
    total = total + finl[0]
    libcrypto.EVP_CIPHER_CTX_free(ctx)
    return ffi.string(out, total)
end

local key = crypto.pbkdf2_hmac_sha1("device-salt-demo", "ywbf", 1000, 32)
print("key len:", #key)

local plaintext = "sk-REPLACE_WITH_YOUR_DEEPSEEK_KEY"
local enc, err = aes_256_ecb_encrypt(plaintext, key)
if not enc then
    print("ENCRYPT FAILED:", tostring(err))
    os.exit(1)
end
print("cipher len:", #enc, "hex:", enc:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))

-- 用设备自带解密函数回验
local cipher = crypto.get_aes_ecb_cipher(32)
local dec, declen = crypto.evp_decrypt(cipher, enc, key, nil)
if not dec then
    print("DECRYPT FAILED")
    os.exit(1)
end
local unpadded = crypto.pkcs7_unpad(dec, declen, 16)
print("roundtrip ok:", unpadded == plaintext, " recovered:", tostring(unpadded))
print("PROBE_C DONE")
