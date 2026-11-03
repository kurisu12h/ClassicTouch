/*
 * it_nandfmt -- the NAND and data-protection steps of a restore, for the A5 iPod touch 5 (n78), then halt.
 *
 * The A4's it_keybag (qemu-ios contrib/it-keybag) on a new A5 device: the kernel's effaceable storage
 * and its NVRAM are partitions of the PPN NAND (IOFlashPartitionScheme's "plog" and "nvrm"), and a blank
 * NAND has no partition table, so first comes what restored does to new flash: the partition scheme's
 * user client, selector 'copy' (kIOFlashPartitionSchemeFormatCmd, IOFlashStorage-716 0x806f730c), which
 * the kernel accepts only with /chosen/system-trusted set and from root. Then as it_keybag: the
 * AppleEffaceableStorage user client's selector 3 (isFormatted) and 4 (format), allowed only under a
 * SecureRoot (the restore RAM disk as md0), and MKBKeyBagCreateSystem on the data volume.
 *
 * Boot the IPSW's RestoreRamDisk (a private copy, tools/a5/n78_nandfmt.py) as md0 with this helper as
 * /usr/local/bin/restored_external and the two-partition USB disk attached; the data volume is the USB
 * disk's second partition, found by its HFS+ signature. Built like contrib/ipad1-guest/build.sh
 * (armv7, dlsym, no IOKit headers).
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

typedef unsigned int mach_port_t, io_object_t;
typedef int kern_return_t;
extern mach_port_t mach_task_self_;
extern int reboot(int);
extern int unmount(const char *, int);

#define RB_HALT 0x08
#define RB_QUICK 0x400
#define DATA_MNT "/mnt2"
#define KEYBAG DATA_MNT "/keybags/systembag.kb"
#define FORMAT_CMD 0x636f7079           /* 'copy' */

static FILE *con;

static void halt(const char *result)
{
    fprintf(con, "it_nandfmt: %s; halting\n", result);
    fflush(con);
    sync();
    reboot(RB_HALT | RB_QUICK);
}

/* The USB disk's data volume: the first /dev/disk<n>s2 with an HFS+ or HFSX volume header. */
static int find_data(char *dev, size_t len)
{
    for (int n = 0; n < 6; n++) {
        unsigned char sig[2];
        int fd;

        snprintf(dev, len, "/dev/disk%ds2", n);
        fd = open(dev, O_RDONLY);
        if (fd < 0) {
            continue;
        }
        if (pread(fd, sig, 2, 1024) == 2 && sig[0] == 'H' && (sig[1] == '+' || sig[1] == 'X')) {
            close(fd);
            return 1;
        }
        close(fd);
    }
    return 0;
}

int main(void)
{
    struct stat st;
    char dev[32];
    int i, status;

    con = fopen("/dev/console", "w");
    if (!con)
        con = stderr;
    void *iok = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_NOW);
    void *mkb = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_NOW);
    void *(*Matching)(const char *) = iok ? dlsym(iok, "IOServiceMatching") : 0;
    io_object_t (*GetService)(mach_port_t, void *) = iok ? dlsym(iok, "IOServiceGetMatchingService") : 0;
    kern_return_t (*Open)(io_object_t, mach_port_t, uint32_t, io_object_t *) = iok ? dlsym(iok, "IOServiceOpen") : 0;
    kern_return_t (*Scalar)(io_object_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *) =
        iok ? dlsym(iok, "IOConnectCallScalarMethod") : 0;
    int (*Create)(void *, const char *) = mkb ? dlsym(mkb, "MKBKeyBagCreateSystem") : 0;
    if (!Matching || !GetService || !Open || !Scalar || !Create) {
        fprintf(con, "it_nandfmt: %s\n", dlerror());
        halt("FAILED: IOKit / MobileKeyBag symbols missing");
        return 1;
    }

    /* 1. The NAND partition table (skipped when a formatted NAND already published its partitions). */
    io_object_t svc = 0, conn = 0;
    for (i = 0; i < 60 && !(svc = GetService(0, Matching("IOFlashPartitionScheme"))); i++)
        sleep(1);
    if (!svc) {
        halt("FAILED: no IOFlashPartitionScheme");
        return 1;
    }
    if (!GetService(0, Matching("AppleEffaceableStorage"))) {
        kern_return_t kr = Open(svc, mach_task_self_, 0, &conn);
        uint32_t n = 0;

        fprintf(con, "it_nandfmt: partition scheme open %x\n", kr);
        fflush(con);
        if (kr) {
            halt("FAILED: cannot open the partition scheme");
            return 1;
        }
        kr = Scalar(conn, FORMAT_CMD, NULL, 0, NULL, &n);
        fprintf(con, "it_nandfmt: NAND partition format -> %x\n", kr);
        fflush(con);
        if (kr) {
            halt("FAILED: NAND partition format");
            return 1;
        }
    }

    /* 2. Effaceable storage, as it_keybag. */
    svc = 0;
    for (i = 0; i < 120 && (!find_data(dev, sizeof(dev)) || !(svc = GetService(0, Matching("AppleEffaceableStorage")))); i++)
        sleep(1);
    if (!svc || !find_data(dev, sizeof(dev))) {
        halt(svc ? "FAILED: no data volume" : "FAILED: no AppleEffaceableStorage");
        return 1;
    }
    kern_return_t kr = Open(svc, mach_task_self_, 0, &conn);
    uint64_t fmt = 0;
    uint32_t n = 1;
    kern_return_t k3 = kr ? kr : Scalar(conn, 3, NULL, 0, &fmt, &n);
    fprintf(con, "it_nandfmt: effaceable open %x isFormatted %x -> %llu\n", kr, k3, fmt);
    if (!k3 && !fmt) {
        n = 0;
        fprintf(con, "it_nandfmt: format %x\n", Scalar(conn, 4, NULL, 0, NULL, &n));
        n = 1;
        k3 = Scalar(conn, 3, NULL, 0, &fmt, &n);
    }
    fflush(con);
    if (k3 || !fmt) {
        halt("FAILED: effaceable storage not formatted");
        return 1;
    }

    /* 3. The system keybag on the data volume. */
    fprintf(con, "it_nandfmt: data volume %s\n", dev);
    pid_t pid = vfork();
    if (pid == 0) {
        execl("/sbin/mount_hfs", "mount_hfs", dev, DATA_MNT, (char *)0);
        _exit(127);
    }
    if (pid < 0 || waitpid(pid, &status, 0) != pid || status) {
        halt("FAILED: mount_hfs");
        return 1;
    }
    int r = Create(NULL, DATA_MNT);
    int ok = !r && !stat(KEYBAG, &st) && st.st_size > 0;
    fprintf(con, "it_nandfmt: MKBKeyBagCreateSystem -> %d, %s %lld bytes\n", r, KEYBAG,
            ok ? (long long)st.st_size : -1LL);
    fflush(con);
    sync();
    unmount(DATA_MNT, 0);
    halt(ok ? "NAND partitioned, effaceable formatted, system keybag created" : "FAILED: no system keybag");
    return !ok;
}
