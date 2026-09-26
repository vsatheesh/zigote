// Count records and residues with kseq.h, for comparison with `zigote --parse-only`.
//
// Built two ways:
//   default      reads through zlib's gzread, as seqtk and most kseq users do
//   -DPLAIN_READ reads the file with read(2), skipping zlib's extra copy
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <zlib.h>
#include "kseq.h"

#ifdef PLAIN_READ
KSEQ_INIT(int, read)
typedef int file_t;
static file_t open_file(const char *path) { return open(path, O_RDONLY); }
static int is_open(file_t f) { return f >= 0; }
static void close_file(file_t f) { close(f); }
#else
KSEQ_INIT(gzFile, gzread)
typedef gzFile file_t;
static file_t open_file(const char *path) { return gzopen(path, "r"); }
static int is_open(file_t f) { return f != NULL; }
static void close_file(file_t f) { gzclose(f); }
#endif

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: kseq-count <file.fa>\n");
        return 2;
    }
    file_t fp = open_file(argv[1]);
    if (!is_open(fp)) {
        fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    kseq_t *seq = kseq_init(fp);
    unsigned long long records = 0, residues = 0;
    int len;
    while ((len = kseq_read(seq)) >= 0) {
        records++;
        residues += (unsigned long long)len;
    }
    kseq_destroy(seq);
    close_file(fp);
    if (len < -1) {
        fprintf(stderr, "parse error %d\n", len);
        return 1;
    }
    printf("%llu %llu\n", records, residues);
    return 0;
}
