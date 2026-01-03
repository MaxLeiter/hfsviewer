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

// libhfs write operations
hfsfile *hfs_create(hfsvol *vol, const char *path, const char *type, const char *creator);
unsigned long hfs_write(hfsfile *file, const void *buf, unsigned long len);
int hfs_mkdir(hfsvol *vol, const char *path);
int hfs_rmdir(hfsvol *vol, const char *path);
int hfs_delete(hfsvol *vol, const char *path);
int hfs_rename(hfsvol *vol, const char *srcpath, const char *dstpath);

#endif /* HFSViewer_Bridging_Header_h */
