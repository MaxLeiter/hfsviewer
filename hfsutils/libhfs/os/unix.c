/*
 * libhfs - library for reading and writing Macintosh HFS volumes
 * Copyright (C) 1996-1998 Robert Leslie
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 *
 * $Id: unix.c,v 1.8 1998/11/02 22:09:13 rob Exp $
 */

#ifdef __linux__
#define _FILE_OFFSET_BITS 64
#define _LARGE_FILES
#endif

# ifdef HAVE_CONFIG_H
#  include "config.h"
# endif

# include <fcntl.h>
# include <unistd.h>
# include <stdlib.h>
# include <string.h>
# include <sys/types.h>
# include <errno.h>
# include <sys/stat.h>
# include <stdint.h>

# ifdef __APPLE__
#  include <sys/ioctl.h>
#  include <sys/disk.h>
# endif

# include "libhfs.h"
# include "os.h"

/*
 * Devices on macOS report a size of zero via lseek(), and raw devices
 * (/dev/rdiskN) only accept I/O in multiples of the device block size,
 * which is 2048 bytes for CD-ROMs. Track enough state here to query the
 * real size and to bounce misaligned requests through an aligned buffer.
 */
typedef struct {
  int fd;
  off_t pos;			/* current offset in bytes */
  off_t size;			/* medium size in bytes, or -1 if unknown */
  unsigned long blksz;		/* device block size in bytes */
} osfile;

/*
 * NAME:	devgeometry()
 * DESCRIPTION:	fill in block size and medium size for a device
 */
static
void devgeometry(osfile *f)
{
  struct stat st;

  f->size  = -1;
  f->blksz = HFS_BLOCKSZ;

  if (fstat(f->fd, &st) == -1 ||
      ! (S_ISCHR(st.st_mode) || S_ISBLK(st.st_mode)))
    return;

# ifdef __APPLE__
  {
    uint32_t blksz;
    uint64_t count;

    if (ioctl(f->fd, DKIOCGETBLOCKSIZE, &blksz) == -1 ||
	ioctl(f->fd, DKIOCGETBLOCKCOUNT, &count) == -1)
      return;

    if (blksz >= HFS_BLOCKSZ && blksz % HFS_BLOCKSZ == 0)
      f->blksz = blksz;

    f->size = (off_t) (count * blksz);
  }
# endif
}

/*
 * NAME:	alignedio()
 * DESCRIPTION:	perform device I/O on a range not aligned to the block size
 */
static
ssize_t alignedio(osfile *f, void *rbuf, const void *wbuf, size_t len)
{
  off_t start, end;
  size_t span, skip;
  ssize_t result;
  unsigned char *buf;

  start = f->pos - f->pos % f->blksz;
  end   = f->pos + len;
  end  += (f->blksz - end % f->blksz) % f->blksz;

  span = (size_t) (end - start);
  skip = (size_t) (f->pos - start);

  if (posix_memalign((void **) &buf, f->blksz, span) != 0)
    {
      errno = ENOMEM;
      return -1;
    }

  result = pread(f->fd, buf, span, start);

  if (wbuf == 0)
    {
      if (result > (ssize_t) skip)
	{
	  result -= skip;
	  if (result > (ssize_t) len)
	    result = len;

	  memcpy(rbuf, buf + skip, result);
	}
      else if (result != -1)
	result = 0;
    }
  else if (result != -1)
    {
      /* read-modify-write the surrounding device blocks */

      if (result == (ssize_t) span)
	{
	  memcpy(buf + skip, wbuf, len);
	  result = pwrite(f->fd, buf, span, start);
	}

      if (result != -1)
	result = (result == (ssize_t) span) ? (ssize_t) len : 0;
    }

  free(buf);

  return result;
}

/*
 * NAME:	os->open()
 * DESCRIPTION:	open and lock a new descriptor from the given path and mode
 */
int os_open(void **priv, const char *path, int mode)
{
  int fd;
  struct flock lock;
  osfile *f;

  switch (mode)
    {
    case HFS_MODE_RDONLY:
      mode = O_RDONLY;
      break;

    case HFS_MODE_RDWR:
    default:
      mode = O_RDWR;
      break;
    }

  fd = open(path, mode);
  if (fd == -1)
    ERROR(errno, "error opening medium");

  /* lock descriptor against concurrent access */

  lock.l_type   = (mode == O_RDONLY) ? F_RDLCK : F_WRLCK;
  lock.l_start  = 0;
  lock.l_whence = SEEK_SET;
  lock.l_len    = 0;

  if (fcntl(fd, F_SETLK, &lock) == -1 &&
      (errno == EACCES || errno == EAGAIN))
    ERROR(EAGAIN, "unable to obtain lock for medium");

  f = ALLOC(osfile, 1);
  if (f == 0)
    ERROR(ENOMEM, 0);

  f->fd  = fd;
  f->pos = 0;
  devgeometry(f);

  *priv = f;

  return 0;

fail:
  if (fd != -1)
    close(fd);

  return -1;
}

/*
 * NAME:	os->close()
 * DESCRIPTION:	close an open descriptor
 */
int os_close(void **priv)
{
  osfile *f = *priv;
  int fd = f->fd;

  *priv = 0;
  FREE(f);

  if (close(fd) == -1)
    ERROR(errno, "error closing medium");

  return 0;

fail:
  return -1;
}

/*
 * NAME:	os->same()
 * DESCRIPTION:	return 1 iff path is same as the open descriptor
 */
int os_same(void **priv, const char *path)
{
  osfile *f = *priv;
  struct stat fdev, dev;

  if (fstat(f->fd, &fdev) == -1 ||
      stat(path, &dev) == -1)
    ERROR(errno, "can't get path information");

  return fdev.st_dev == dev.st_dev &&
         fdev.st_ino == dev.st_ino;

fail:
  return -1;
}

/*
 * NAME:	os->seek()
 * DESCRIPTION:	set a descriptor's seek pointer (offset in blocks)
 */
unsigned long os_seek(void **priv, unsigned long offset)
{
  osfile *f = *priv;
  off_t result;

  /* offset == -1 special; seek to last block of device */

  if (offset == (unsigned long) -1)
    result = (f->size != -1) ? f->size : lseek(f->fd, 0, SEEK_END);
  else
    result = (off_t) offset << HFS_BLOCKSZ_BITS;

  if (result == -1)
    ERROR(errno, "error seeking medium");

  f->pos = result;

  return (unsigned long) result >> HFS_BLOCKSZ_BITS;

fail:
  return -1;
}

/*
 * NAME:	os->read()
 * DESCRIPTION:	read blocks from an open descriptor
 */
unsigned long os_read(void **priv, void *buf, unsigned long len)
{
  osfile *f = *priv;
  size_t bytes = len << HFS_BLOCKSZ_BITS;
  ssize_t result;

  if (f->pos % f->blksz == 0 && bytes % f->blksz == 0)
    result = pread(f->fd, buf, bytes, f->pos);
  else
    result = alignedio(f, buf, 0, bytes);

  if (result == -1)
    ERROR(errno, "error reading from medium");

  f->pos += result;

  return (unsigned long) result >> HFS_BLOCKSZ_BITS;

fail:
  return -1;
}

/*
 * NAME:	os->write()
 * DESCRIPTION:	write blocks to an open descriptor
 */
unsigned long os_write(void **priv, const void *buf, unsigned long len)
{
  osfile *f = *priv;
  size_t bytes = len << HFS_BLOCKSZ_BITS;
  ssize_t result;

  if (f->pos % f->blksz == 0 && bytes % f->blksz == 0)
    result = pwrite(f->fd, buf, bytes, f->pos);
  else
    result = alignedio(f, 0, buf, bytes);

  if (result == -1)
    ERROR(errno, "error writing to medium");

  f->pos += result;

  return (unsigned long) result >> HFS_BLOCKSZ_BITS;

fail:
  return -1;
}
