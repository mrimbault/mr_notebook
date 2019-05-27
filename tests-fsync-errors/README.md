
**WARNING: this is a work in progress, the results are inconclusive at the time
of writing**

# PostgreSQL and fsync

Quick reminder of the issue:

> The fundamental problem is that postgres assumed that any IO error would
> be reported at fsync time, and that the error would be reported until
> resolved. That's not true in several operating systems, linux included.
Source : [[https://lwn.net/Articles/753184/]]

An important word of caution:
These testing scripts are designed to produce false I/O errors that corrupt
data easily and frequently, in a way to make the problem easily reproductible.
In no way is this representative of an expected behaviour on actual
environments: this behaviour would be very hard to get on an environment solely
badly configured or encountering real hardware failures, and impossible to get
on any normal, sane environment.  Also, that should be obvious but I'll still
write it: **do not run these scripts on any machine containing data you want to
keep** (ie use a dedicated VM or container).

Various pointers about problem these scripts try to reproduce:
- https://wiki.postgresql.org/wiki/Fsync_Errors

Scripts inspired by Craig Ringer test case:
- https://github.com/ringerc/scrapcode/tree/master/testcases/fsync-error-clear

## Mechanics analysis

As of 2019, May 27 - latest PostgreSQL version is 11.3.

### File manipulation

From the file manipulation point of view.

Starting point, the `fd.c` file: https://doxygen.postgresql.org/fd_8c_source.html

PostgreSQL manages "Virtual file descriptors" (VFD) to avoid hitting system
limits on open files.  For this to work, most of PostgreSQL interactions with
actual files are done using this interface.

PostgreSQL uses a LRU ring to manage these VFD, and keeps FD references for
when it is required to free some.  The goal here is to avoid resource
saturation on OSes that do not enforce sane open file descriptors limits (as
shown with `ulimit -n` on Linux).  The ring's max size is partly configurable
using `max_files_per_process` setting (it is taken in account while defining
the internal variable `max_safe_fds` used by the actual code, but PostgreSQL
also tries to compute actual system limits including already opened file
descriptors).

See the following comments for detailed descriptions:
- https://doxygen.postgresql.org/fd_8c_source.html#l00262
- https://doxygen.postgresql.org/fd_8c_source.html#l00898

Interesting quote:
> * Only VFD elements that are currently really open (have an FD assigned) are
> * in the Lru ring.  Elements that are "virtually" open can be recognized
> * by having a non-null fileName field.


When a PostgreSQL backend has to interact with a file (to read, write, sync,
etc.), it starts with calling for `FileAccess()` function
(https://doxygen.postgresql.org/fd_8c.html#a72019405c5608c4d3d599abfcfda2503).
This function will insert the FD into the Lru ring if not already present,
possibly removing the least recently used entries in the process.  This Lru
ring cleaning is ultimately done by calling the `ReleaseLruFiles()` function to
remove entries until the number of entries is lower than `max_safe_fds`.  So
even if a running backend process has previously accessed a file, there is not
guarantee that the related FD is still opened.

In any case, when the backend is closed at disconnection, if some FD are still
in use by the process, they are also closed.  But dirty data probably still is
in the shared buffers: that's the checkpointer's job to write this data back,
possibly opening again the files before "fsyncing" them.


### Checkpointer

FIXME TODO


# Reproducting the problem

Reproducing the problem before 11.2 where PostgreSQL retries a failed `fsync`
and it succeeds, leading to data corruption, is simple enough.  Craig Ringer
wrote a test case
(https://github.com/ringerc/scrapcode/tree/master/testcases/fsync-error-clear),
and my own scripts also allow to reproduce it.

In my case, I added some (probably too much) complexity in order to demonstrate
that the data is indeed corrupted, and to test several configurations.

My test scenario does the following:
- have a FS with a few bad blocks inside, so we can have intermitent I/O errors
  (a necessary condition to reproduce the problem)
- create a tablespace on this FS, and a table on the tablespace
- insert some data to try to write to a bad block AND register some meta-data
  related to this write so we can later compare if this data was lost (using a
  foreign key), and what checkpoint should have detected the error (based on
  write time, LSN, etc.)
- disconnect the backend, so that the FD are closed (should rise the
  probability that the error is not reported, at least on unpatched kernels
  4.13, 4.15 and 4.16, and possibly before 4.13)
- write some data on another, sane, table, to dirty more buffers and accelerate
  the writeback
- wait for a timed checkpoint to happen (to ensure only one of these writes is
  done for every checkpoint)
- rince and repeat for enough time to have several timed checkpoints triggered
- force one last checkpoint, and shutdown propertly (mode "fast", NOT
  "immediate", so another immediate checkpoint occurs here)
- sync filesystem cache to storage, and force empty it
- restart the PostgreSQL instance, and compute a report on both the missing
  data, and the various logged events (system and PostgreSQL errors, and
  PostgreSQL checkpoints details)

Also, on PostgreSQL versions where PANIC is triggered on fsync errors (11.2+
for 11 major branch), the scripts force a WAL reset to allow the instance to
start again, and the testing to continue.  Obviously, that allows live data to
be corrupted, but that is an expected consequence of forcing WAL reset,
unrelated to the problem studied here.  In consequence these data corruptions
are excluded from final analysis.

Now, what is much more difficult (at least to me) is to reproduce the second
problem, when PostgreSQL never gets the error.  At the time of writing, I was
never able to trigger it using this basic test, even on versions of kernel
older that 4.13.  In a way, that is good news, but being able to reproduce the
problem would help to know what configurations may be more at risk, and measure
the positive effects of patchs written to fix this issue.

Various ideas about how to improve the testing:
- various FS cache writeback configurations (`dirty_*`)
- various PostgreSQL configurations (`*_flush_after`, `bgwriter_*`,
  `checkpoint_completion_target`, `checkpoint_timeout`)
- test while putting intense memory pressure on the OS
  - filling a huge `shared_buffers` to saturate FS cache with dirty data to sync
  - using `work_mem` and private memory to apply more pressure
  - use pgbench with an aggressive mixed read/write workload
- use other test cases that the "local bad blocks" one:
  - local full FS (should not cause corruptions)
  - remote full FS (NFS)
  - hypervisor full FS using thin provisionned volume
  - remote bad blocks (NFS)
  - hypervisor bad blocks
  - same three with transient permission problems (effect of an erroneous
    `chmod -R`)


## Environment used

- RAM: 1048576 KiB configured
- CPU: 4
- Virtualization: vagrant/libvirt/KVM
- Virtual volume type: qcow2
- env1:
  - OS: `CentOS Linux release 7.6.1810 (Core)`
  - vagrant box: `centos/7         (libvirt, 1811.02)`
  - kernel: `Linux pg 3.10.0-957.1.3.el7.x86_64 #1 SMP Thu Nov 29 14:49:43 UTC 2018 x86_64 x86_64 x86_64 GNU/Linux`
- env2:
  - OS: `Ubuntu 18.04.2 LTS`
  - vagrant box: `generic/ubuntu1804 (libvirt, 1.9.14)`
  - kernel: `Linux pg 4.15.0-50-generic #54-Ubuntu SMP Mon May 6 18:46:08 UTC 2019 x86_64 x86_64 x86_64 GNU/Linux`
- storage and FS: local XFS on logical volume containing bad blocks




# Annexes


## FS configuration

XFS:

FIXME http://ftp.ntu.edu.tw/linux/utils/fs/xfs/docs/xfs_filesystem_structure.pdf

FIXME https://righteousit.wordpress.com/tag/xfs/

FIXME simple geometry to avoid running into errors if metadata is currupted

I initially thought that disabling autovacuum would be sufficient to avoid the
FSM file creation, but it turns out that it is created as soon as the second
data block is allocated (FIXME source ref).  And the FSM file can not be moved
elsewhere, it stays this the data segment.  So to avoid running into issues
with a corrupted FSM that is not what I intended to test, I first needed to
find where the FSM file would be created for a given FS type.

Here it is with XFS:
```
[root@pg ~]# hdparm --fibmap /mnt/error_mount/data/PG_11_201809051/13287/16387_fsm

/mnt/error_mount/data/PG_11_201809051/13287/16387_fsm:
 filesystem blocksize 4096, begins at LBA 0; assuming 512 byte sectors.
  byte_offset  begin_LBA    end_LBA    sectors
             0       6992       7039         48
```

And the ranges for the corresponding data file:
```
[root@pg ~]# hdparm --fibmap /mnt/error_mount/data/PG_11_201809051/13287/16387

/mnt/error_mount/data/PG_11_201809051/13287/16387:
 filesystem blocksize 4096, begins at LBA 0; assuming 512 byte sectors.
  byte_offset  begin_LBA    end_LBA    sectors
             0       6976       6991         16
          8192       7040       7407        368
```
So what interests me is the starting point of the second range, the logical
block address "7040".  With a sector size of 512 bytes, that gives us a
starting point for corrupted blocks at 3604480 bytes, or 880 blocks of size
4096 bytes.

This way, errors will start to raise immediately after the FSM has been
created, and should only affect data segment after the first block.

So I had to exclude this section from the error generating sectors.


