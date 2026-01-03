//
//  HFSViewer-Bridging-Header.h
//  com.maxleiter.HFSViewer
//

#ifndef HFSViewer_Bridging_Header_h
#define HFSViewer_Bridging_Header_h

#include <stdint.h>
#include <sys/types.h>
#include <time.h>

// ============================================================================
// libhfs - Classic HFS Support
// ============================================================================

#define HFS_BLOCKSZ         512
#define HFS_MAX_FLEN        31
#define HFS_MAX_VLEN        27

#define HFS_ISDIR          0x0001
#define HFS_ISLOCKED       0x0002

#define HFS_MODE_RDONLY    0
#define HFS_MODE_RDWR      1
#define HFS_MODE_ANY       2

typedef struct _hfsvol_  hfsvol;
typedef struct _hfsfile_ hfsfile;
typedef struct _hfsdir_  hfsdir;

typedef struct {
    char name[HFS_MAX_VLEN + 1];
    int flags;
    unsigned long totbytes;
    unsigned long freebytes;
    unsigned long alblocksz;
    unsigned long clumpsz;
    unsigned long numfiles;
    unsigned long numdirs;
    time_t crdate;
    time_t mddate;
    time_t bkdate;
    unsigned long blessed;
} hfsvolent;

typedef struct {
    char name[HFS_MAX_FLEN + 1];
    int flags;
    unsigned long cnid;
    unsigned long parid;
    time_t crdate;
    time_t mddate;
    time_t bkdate;
    short fdflags;
    struct {
        signed short v;
        signed short h;
    } fdlocation;
    union {
        struct {
            unsigned long dsize;
            unsigned long rsize;
            char type[5];
            char creator[5];
        } file;
        struct {
            unsigned short valence;
            struct {
                signed short top;
                signed short left;
                signed short bottom;
                signed short right;
            } rect;
        } dir;
    } u;
} hfsdirent;

extern const char *hfs_error;

// libhfs functions
hfsvol *hfs_mount(const char *path, int partition, int mode);
int hfs_umount(hfsvol *vol);
int hfs_vstat(hfsvol *vol, hfsvolent *ent);
hfsdir *hfs_opendir(hfsvol *vol, const char *path);
int hfs_readdir(hfsdir *dir, hfsdirent *ent);
int hfs_closedir(hfsdir *dir);
hfsfile *hfs_open(hfsvol *vol, const char *path);
unsigned long hfs_read(hfsfile *file, void *buf, unsigned long len);
unsigned long hfs_seek(hfsfile *file, long offset, int whence);
int hfs_close(hfsfile *file);
int hfs_stat(hfsvol *vol, const char *path, hfsdirent *ent);
int hfs_chdir(hfsvol *vol, const char *path);
unsigned long hfs_getcwd(hfsvol *vol);
int hfs_setcwd(hfsvol *vol, unsigned long cnid);

// ============================================================================
// libfshfs - HFS+ Support
// ============================================================================

#include <stdint.h>
#include <sys/types.h>

// Define types needed by libfshfs
typedef uint32_t size32_t;
typedef int32_t ssize32_t;
typedef uint64_t size64_t;
typedef int64_t ssize64_t;
typedef int64_t off64_t;

// Opaque pointer types for libfshfs - use void* for proper pointer semantics
typedef void* libfshfs_error_t;
typedef void* libfshfs_volume_t;
typedef void* libfshfs_file_entry_t;
typedef void* libfshfs_data_stream_t;
typedef void* libfshfs_extended_attribute_t;

// Library version
const char *libfshfs_get_version(void);

// Access flags
int libfshfs_get_access_flags_read(void);

// Error functions
void libfshfs_error_free(libfshfs_error_t *error);
int libfshfs_error_sprint(libfshfs_error_t error, char *string, size_t size);

// Volume signature check
int libfshfs_check_volume_signature(const char *filename, libfshfs_error_t *error);

// Volume functions
int libfshfs_volume_initialize(libfshfs_volume_t *volume, libfshfs_error_t *error);
int libfshfs_volume_free(libfshfs_volume_t *volume, libfshfs_error_t *error);
int libfshfs_volume_open(libfshfs_volume_t volume, const char *filename, int access_flags, libfshfs_error_t *error);
int libfshfs_volume_close(libfshfs_volume_t volume, libfshfs_error_t *error);

int libfshfs_volume_get_utf8_name_size(libfshfs_volume_t volume, size_t *utf8_string_size, libfshfs_error_t *error);
int libfshfs_volume_get_utf8_name(libfshfs_volume_t volume, uint8_t *utf8_string, size_t utf8_string_size, libfshfs_error_t *error);

int libfshfs_volume_get_root_directory(libfshfs_volume_t volume, libfshfs_file_entry_t *file_entry, libfshfs_error_t *error);
int libfshfs_volume_get_file_entry_by_utf8_path(libfshfs_volume_t volume, const uint8_t *utf8_string, size_t utf8_string_length, libfshfs_file_entry_t *file_entry, libfshfs_error_t *error);

// File entry functions
int libfshfs_file_entry_free(libfshfs_file_entry_t *file_entry, libfshfs_error_t *error);

int libfshfs_file_entry_get_identifier(libfshfs_file_entry_t file_entry, uint32_t *identifier, libfshfs_error_t *error);
int libfshfs_file_entry_get_parent_identifier(libfshfs_file_entry_t file_entry, uint32_t *parent_identifier, libfshfs_error_t *error);

int libfshfs_file_entry_get_creation_time(libfshfs_file_entry_t file_entry, uint32_t *hfs_time, libfshfs_error_t *error);
int libfshfs_file_entry_get_modification_time(libfshfs_file_entry_t file_entry, uint32_t *hfs_time, libfshfs_error_t *error);
int libfshfs_file_entry_get_access_time(libfshfs_file_entry_t file_entry, uint32_t *hfs_time, libfshfs_error_t *error);

int libfshfs_file_entry_get_file_mode(libfshfs_file_entry_t file_entry, uint16_t *file_mode, libfshfs_error_t *error);
int libfshfs_file_entry_get_owner_identifier(libfshfs_file_entry_t file_entry, uint32_t *owner_identifier, libfshfs_error_t *error);
int libfshfs_file_entry_get_group_identifier(libfshfs_file_entry_t file_entry, uint32_t *group_identifier, libfshfs_error_t *error);

int libfshfs_file_entry_get_utf8_name_size(libfshfs_file_entry_t file_entry, size_t *utf8_string_size, libfshfs_error_t *error);
int libfshfs_file_entry_get_utf8_name(libfshfs_file_entry_t file_entry, uint8_t *utf8_string, size_t utf8_string_size, libfshfs_error_t *error);

int libfshfs_file_entry_get_size(libfshfs_file_entry_t file_entry, size64_t *size, libfshfs_error_t *error);

int libfshfs_file_entry_get_number_of_sub_file_entries(libfshfs_file_entry_t file_entry, int *number_of_sub_file_entries, libfshfs_error_t *error);
int libfshfs_file_entry_get_sub_file_entry_by_index(libfshfs_file_entry_t file_entry, int sub_file_entry_index, libfshfs_file_entry_t *sub_file_entry, libfshfs_error_t *error);

// File reading
ssize_t libfshfs_file_entry_read_buffer(libfshfs_file_entry_t file_entry, void *buffer, size_t buffer_size, libfshfs_error_t *error);
ssize_t libfshfs_file_entry_read_buffer_at_offset(libfshfs_file_entry_t file_entry, void *buffer, size_t buffer_size, off64_t offset, libfshfs_error_t *error);
off64_t libfshfs_file_entry_seek_offset(libfshfs_file_entry_t file_entry, off64_t offset, int whence, libfshfs_error_t *error);

// Extended attributes
int libfshfs_file_entry_get_number_of_extended_attributes(libfshfs_file_entry_t file_entry, int *number_of_extended_attributes, libfshfs_error_t *error);
int libfshfs_file_entry_get_extended_attribute_by_index(libfshfs_file_entry_t file_entry, int extended_attribute_index, libfshfs_extended_attribute_t *extended_attribute, libfshfs_error_t *error);

int libfshfs_extended_attribute_free(libfshfs_extended_attribute_t *extended_attribute, libfshfs_error_t *error);
int libfshfs_extended_attribute_get_utf8_name_size(libfshfs_extended_attribute_t extended_attribute, size_t *utf8_string_size, libfshfs_error_t *error);
int libfshfs_extended_attribute_get_utf8_name(libfshfs_extended_attribute_t extended_attribute, uint8_t *utf8_string, size_t utf8_string_size, libfshfs_error_t *error);
int libfshfs_extended_attribute_get_size(libfshfs_extended_attribute_t extended_attribute, size64_t *size, libfshfs_error_t *error);

// Resource fork
int libfshfs_file_entry_has_resource_fork(libfshfs_file_entry_t file_entry, libfshfs_error_t *error);
int libfshfs_file_entry_get_resource_fork(libfshfs_file_entry_t file_entry, libfshfs_data_stream_t *data_stream, libfshfs_error_t *error);

int libfshfs_data_stream_free(libfshfs_data_stream_t *data_stream, libfshfs_error_t *error);
int libfshfs_data_stream_get_size(libfshfs_data_stream_t data_stream, size64_t *size, libfshfs_error_t *error);

// Symbolic links
int libfshfs_file_entry_get_utf8_symbolic_link_target_size(libfshfs_file_entry_t file_entry, size_t *utf8_string_size, libfshfs_error_t *error);
int libfshfs_file_entry_get_utf8_symbolic_link_target(libfshfs_file_entry_t file_entry, uint8_t *utf8_string, size_t utf8_string_size, libfshfs_error_t *error);

#endif /* HFSViewer_Bridging_Header_h */
