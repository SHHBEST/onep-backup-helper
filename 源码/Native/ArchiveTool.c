#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <locale.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Public libarchive ABI subset. macOS ships the library but not its SDK headers.
   No third-party implementation is embedded; link to the system libarchive.2. */
struct archive;
struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern struct archive_entry *archive_entry_new(void);
extern void archive_entry_free(struct archive_entry *);
extern void archive_entry_set_pathname(struct archive_entry *, const char *);
extern void archive_entry_set_filetype(struct archive_entry *, unsigned int);
extern void archive_entry_set_perm(struct archive_entry *, mode_t);
extern void archive_entry_set_size(struct archive_entry *, int64_t);
extern void archive_entry_set_mtime(struct archive_entry *, time_t, long);
extern struct archive *archive_write_new(void);
extern int archive_write_set_format_zip(struct archive *);
extern int archive_write_open_fd(struct archive *, int);
extern int archive_write_header(struct archive *, struct archive_entry *);
extern ssize_t archive_write_data(struct archive *, const void *, size_t);
extern int archive_write_close(struct archive *);
extern int archive_write_free(struct archive *);

static const char marker[] = ".1p-folder-format";
static const char magic[] = "1P backup folder ZIP v1\n";

static void die(const char *message) {
    fprintf(stderr, "Folder archive: %s\n", message);
    exit(1);
}

static void check(int status, struct archive *a) {
    if (status != 0) {
        const char *error = archive_error_string(a);
        die(error ? error : "archive operation failed");
    }
}

static void write_bytes(struct archive *a, const void *data, size_t size) {
    const char *p = data;
    while (size) {
        ssize_t n = archive_write_data(a, p, size);
        if (n <= 0) die("could not write ZIP data");
        p += n;
        size -= (size_t)n;
    }
}

static void header(struct archive *a, const char *name, mode_t type, int64_t size, time_t mtime) {
    struct archive_entry *entry = archive_entry_new();
    if (!entry) die("out of memory");
    archive_entry_set_pathname(entry, name);
    archive_entry_set_filetype(entry, type);
    archive_entry_set_perm(entry, type == S_IFDIR ? 0700 : 0600);
    archive_entry_set_size(entry, size);
    archive_entry_set_mtime(entry, mtime, 0);
    check(archive_write_header(a, entry), a);
    archive_entry_free(entry);
}

static int safe_components(const char *path) {
    if (!path || !*path || *path == '/' || strchr(path, '\\') || strlen(path) >= PATH_MAX) return 0;
    const char *p = path;
    while (*p) {
        const char *slash = strchr(p, '/');
        size_t len = slash ? (size_t)(slash - p) : strlen(p);
        if (!len || (len == 1 && *p == '.') || (len == 2 && !strncmp(p, "..", 2))) return 0;
        if (!slash || !slash[1]) break;
        p = slash + 1;
    }
    return 1;
}

static void create_zip(const char *source, const char *output) {
    char root[PATH_MAX];
    if (!realpath(source, root)) die("could not resolve source folder");
    struct stat st;
    if (lstat(root, &st) || !S_ISDIR(st.st_mode)) die("source must be a folder");
    int out = open(output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (out < 0) die("ZIP output already exists or is not writable");
    struct archive *a = archive_write_new();
    if (!a) die("out of memory");
    check(archive_write_set_format_zip(a), a);
    check(archive_write_open_fd(a, out), a);
    header(a, marker, S_IFREG, sizeof(magic) - 1, st.st_mtime);
    write_bytes(a, magic, sizeof(magic) - 1);
    char *paths[] = {root, NULL};
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!tree) die("could not enumerate folder");
    FTSENT *node;
    size_t rootlen = strlen(root);
    for (;;) {
        errno = 0;
        node = fts_read(tree);
        if (!node) { if (errno) die("folder enumeration failed"); break; }
        if (node->fts_info == FTS_DP) continue;
        if (node->fts_info != FTS_D && node->fts_info != FTS_F)
            die("only regular files and folders are supported; remove symbolic links or special files");
        const char *relative = node->fts_level == 0 ? "" : node->fts_path + rootlen + 1;
        if (*relative && !safe_components(relative)) die("unsupported path inside folder (dot components or backslash)");
        char name[PATH_MAX];
        if (snprintf(name, sizeof(name), "contents/%s", relative) >= (int)sizeof(name)) die("path too long");
        if (node->fts_info == FTS_D) {
            header(a, name, S_IFDIR, 0, node->fts_statp->st_mtime);
            continue;
        }
        int fd = open(node->fts_accpath, O_RDONLY | O_NOFOLLOW);
        if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode)
            || st.st_ino != node->fts_statp->st_ino || st.st_dev != node->fts_statp->st_dev)
            die("file changed or could not be read while packing");
        header(a, name, S_IFREG, st.st_size, st.st_mtime);
        char buffer[65536];
        int64_t total = 0;
        ssize_t n;
        while ((n = read(fd, buffer, sizeof(buffer))) > 0) {
            if (n > st.st_size - total) die("file grew while packing; retry with an idle folder");
            write_bytes(a, buffer, (size_t)n);
            total += n;
        }
        struct stat after;
        if (n < 0 || total != st.st_size || fstat(fd, &after)
            || st.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
            || st.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec)
            die("file changed while packing; retry with an idle folder");
        close(fd);
    }
    fts_close(tree);
    check(archive_write_close(a), a);
    archive_write_free(a);
    if (close(out)) die("could not close ZIP output");
}

static struct archive *open_zip(const char *path) {
    struct archive *a = archive_read_new();
    if (!a) die("out of memory");
    check(archive_read_support_format_zip(a), a);
    if (archive_read_open_filename(a, path, 65536) != 0) { archive_read_free(a); return NULL; }
    return a;
}

static int read_marker(struct archive *a) {
    struct archive_entry *entry;
    if (!a || archive_read_next_header(a, &entry) != 0) return 0;
    const char *name = archive_entry_pathname(entry);
    if (!name || strcmp(name, marker) || archive_entry_size(entry) != sizeof(magic) - 1
        || archive_entry_filetype(entry) != S_IFREG || archive_entry_symlink(entry) || archive_entry_hardlink(entry)) return 0;
    char data[sizeof(magic)];
    size_t total = 0;
    ssize_t n;
    while (total < sizeof(data) && (n = archive_read_data(a, data + total, sizeof(data) - total)) > 0) total += n;
    return total == sizeof(magic) - 1 && !memcmp(data, magic, total);
}

/* Resolve every directory with openat(O_NOFOLLOW); archive members never become
   filesystem paths outside the private staging directory, even through links. */
static int parent_fd(int root, char *path, char **leaf) {
    int fd = dup(root);
    if (fd < 0) die("could not open extraction root");
    char *p = path, *slash;
    while ((slash = strchr(p, '/'))) {
        *slash = 0;
        if (mkdirat(fd, p, 0700) && errno != EEXIST) die("could not create extraction directory");
        int next = openat(fd, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (next < 0) die("unsafe extraction directory");
        close(fd); fd = next; p = slash + 1;
    }
    *leaf = p;
    return fd;
}

static void extract_zip(const char *source, const char *destination) {
    struct archive *a = open_zip(source);
    if (!read_marker(a)) die("not a supported 1P folder ZIP");
    int root = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (root < 0) die("extraction destination must be a private directory");
    struct archive_entry *entry;
    int status;
    while ((status = archive_read_next_header(a, &entry)) == 0) {
        const char *name = archive_entry_pathname(entry);
        mode_t type = archive_entry_filetype(entry);
        if (!safe_components(name) || strncmp(name, "contents/", 9)
            || archive_entry_symlink(entry) || archive_entry_hardlink(entry)
            || (type != S_IFDIR && type != S_IFREG))
            die("unsafe ZIP member: traversal, links and special files are not allowed");
        char path[PATH_MAX];
        strcpy(path, name);
        size_t len = strlen(path);
        if (path[len - 1] == '/') path[--len] = 0;
        char *leaf;
        int parent = parent_fd(root, path, &leaf);
        if (type == S_IFDIR) {
            if (mkdirat(parent, leaf, 0700) && errno != EEXIST) die("could not restore directory");
            int dir = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (dir < 0) die("unsafe directory entry");
            close(dir);
        } else {
            int fd = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (fd < 0) die("duplicate or conflicting ZIP member; nothing will be overwritten");
            char buffer[65536];
            ssize_t n;
            int64_t total = 0, expected = archive_entry_size(entry);
            if (expected < 0) die("invalid ZIP file size");
            while ((n = archive_read_data(a, buffer, sizeof(buffer))) > 0) {
                if (n > expected - total) die("ZIP file exceeds its declared size");
                ssize_t offset = 0;
                while (offset < n) {
                    ssize_t written = write(fd, buffer + offset, (size_t)(n - offset));
                    if (written <= 0) die("could not restore file; check free disk space");
                    offset += written;
                }
                total += n;
            }
            if (n < 0 || total != expected) die("ZIP data or CRC is invalid");
            if (close(fd)) die("could not close restored file");
        }
        close(parent);
    }
    if (status != 1) check(status, a); /* ARCHIVE_EOF */
    struct stat restored;
    if (fstatat(root, "contents", &restored, AT_SYMLINK_NOFOLLOW) || !S_ISDIR(restored.st_mode))
        die("ZIP is missing its contents directory");
    close(root);
    archive_read_free(a);
}

int main(int argc, char **argv) {
    setlocale(LC_ALL, "en_US.UTF-8");
    umask(077);
    if (argc == 3 && !strcmp(argv[1], "probe")) {
        struct archive *a = open_zip(argv[2]);
        int valid = read_marker(a);
        if (a) archive_read_free(a);
        return valid ? 0 : 1;
    }
    if (argc != 4) die("usage: archive-tool {create|extract} source destination");
    if (!strcmp(argv[1], "create")) create_zip(argv[2], argv[3]);
    else if (!strcmp(argv[1], "extract")) extract_zip(argv[2], argv[3]);
    else die("unknown archive command");
    return 0;
}
