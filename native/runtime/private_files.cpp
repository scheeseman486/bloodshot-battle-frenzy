#include "private_files.h"
#include <godot_cpp/core/class_db.hpp>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <aclapi.h>
#include <vector>
#else
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif
using namespace godot;
namespace bloodshot {
void BloodshotPrivateFiles::_bind_methods() {
    ClassDB::bind_method(D_METHOD("protect", "path", "directory"), &BloodshotPrivateFiles::protect);
}
int BloodshotPrivateFiles::protect(const String &path, bool directory) {
#ifdef _WIN32
    // Work through handles, reject reparse points, and require current ownership.
    // Protected inheritable DACL prevents permissive parent ACLs leaking keys.
    const auto wide = path.utf16();
    HANDLE file = CreateFileW(reinterpret_cast<LPCWSTR>(wide.get_data()),
        READ_CONTROL | WRITE_DAC | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), nullptr);
    if (file == INVALID_HANDLE_VALUE) return ERR_FILE_NO_PERMISSION;
    BY_HANDLE_FILE_INFORMATION info{};
    HANDLE token = nullptr;
    DWORD size = 0;
    PACL acl = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    PSID owner = nullptr;
    bool ok = GetFileInformationByHandle(file, &info) &&
        !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
        bool(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == directory &&
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token);
    if (ok) GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::vector<unsigned char> user(size);
    ok = ok && size > 0 && GetTokenInformation(token, TokenUser, user.data(), size, &size);
    if (ok) ok = GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
        &owner, nullptr, nullptr, nullptr, &descriptor) == ERROR_SUCCESS;
    auto *principal = reinterpret_cast<TOKEN_USER *>(user.data());
    ok = ok && owner && EqualSid(owner, principal->User.Sid);
    EXPLICIT_ACCESSW access{};
    if (ok) {
        access.grfAccessPermissions = FILE_ALL_ACCESS;
        access.grfAccessMode = SET_ACCESS;
        access.grfInheritance = directory ? SUB_CONTAINERS_AND_OBJECTS_INHERIT : NO_INHERITANCE;
        access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
        access.Trustee.TrusteeType = TRUSTEE_IS_USER;
        access.Trustee.ptstrName = reinterpret_cast<LPWSTR>(principal->User.Sid);
        ok = SetEntriesInAclW(1, &access, nullptr, &acl) == ERROR_SUCCESS;
    }
    if (ok) ok = SetSecurityInfo(file, SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
        nullptr, nullptr, acl, nullptr) == ERROR_SUCCESS;
    // Verify the filesystem actually retained the restrictive ACL. Filesystems
    // or compatibility layers unable to enforce it must not report protection.
    PSECURITY_DESCRIPTOR verified = nullptr;
    PACL actual = nullptr;
    if (ok) ok = GetSecurityInfo(file, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
        nullptr, nullptr, &actual, nullptr, &verified) == ERROR_SUCCESS;
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    void *raw_ace = nullptr;
    if (ok) ok = actual && actual->AceCount == 1 &&
        GetSecurityDescriptorControl(verified, &control, &revision) &&
        (control & SE_DACL_PROTECTED) && GetAce(actual, 0, &raw_ace);
    if (ok) {
        auto *ace = reinterpret_cast<ACCESS_ALLOWED_ACE *>(raw_ace);
        ok = ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
            ace->Mask == FILE_ALL_ACCESS && EqualSid(&ace->SidStart, principal->User.Sid);
    }
    if (verified) LocalFree(verified);
    if (acl) LocalFree(acl);
    if (descriptor) LocalFree(descriptor);
    if (token) CloseHandle(token);
    CloseHandle(file);
    return ok ? OK : ERR_FILE_NO_PERMISSION;
#else
    const auto name = path.utf8();
    const int fd = open(name.get_data(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : 0));
    if (fd < 0) return ERR_FILE_NO_PERMISSION;
    struct stat info{};
    bool ok = fstat(fd, &info) == 0 && info.st_uid == geteuid() &&
        (directory ? S_ISDIR(info.st_mode) : S_ISREG(info.st_mode)) &&
        fchmod(fd, directory ? 0700 : 0600) == 0;
    if (ok) ok = fstat(fd, &info) == 0 && (info.st_mode & 07777) == (directory ? 0700 : 0600);
    close(fd);
    return ok ? OK : ERR_FILE_NO_PERMISSION;
#endif
}
}
