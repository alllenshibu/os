#include <ctype.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t bool;
#define true 1
#define false 0

typedef struct
{
    uint8_t boot_jump_instruction[3];
    uint8_t oem_identifier[8];
    uint16_t bytes_per_sector;
    uint8_t sectors_per_cluster;
    uint16_t reserved_sectors;
    uint8_t fat_count;
    uint16_t directory_entries_count;
    uint16_t total_sectors;
    uint8_t meta_descriptor_type;
    uint16_t sectors_per_fat;
    uint16_t sectors_per_track;
    uint16_t heads;
    uint32_t hidden_sectors;
    uint32_t large_total_sectors;

    // extended boot record
    uint8_t drive_number;
    uint8_t _reserved;
    uint8_t signature;
    uint32_t volume_id;
    uint8_t volume_label[11];
    uint8_t system_id[8];
} __attribute__((packed)) boot_sector;

typedef struct
{
    uint8_t name[11];
    uint8_t attributes;
    uint8_t _reserved;
    uint8_t creation_time_tenths;
    uint16_t creation_time;
    uint16_t creation_date;
    uint16_t last_access_date;
    uint16_t first_cluster_high;
    uint16_t last_modification_time;
    uint16_t last_modification_date;
    uint16_t first_cluster_low;
    uint32_t size;
}
__attribute__((packed)) directory_entry;

boot_sector g_boot_sector;
uint8_t *g_fat = NULL;
directory_entry *g_root_directory = NULL;
uint32_t g_root_directory_end;

bool read_boot_sector(FILE *disk)
{
    return fread(&g_boot_sector, sizeof(g_boot_sector), 1, disk);
}

bool read_sectors(FILE *disk, uint32_t lba, uint32_t count, void *buffer)
{
    bool ok = true;
    ok = ok && fseek(disk, lba * g_boot_sector.bytes_per_sector, SEEK_SET) == 0;
    ok = ok && fread(buffer, g_boot_sector.bytes_per_sector, count, disk) == count;
    return ok;
}

bool read_fat(FILE *disk)
{
    g_fat = (uint8_t *)malloc(g_boot_sector.sectors_per_fat * g_boot_sector.bytes_per_sector);
    return read_sectors(disk, g_boot_sector.reserved_sectors, g_boot_sector.sectors_per_fat, g_fat);
}

bool read_root_directory(FILE *disk)
{
    uint32_t lba = g_boot_sector.reserved_sectors + g_boot_sector.sectors_per_fat * g_boot_sector.fat_count;
    uint32_t size = sizeof(directory_entry) * g_boot_sector.directory_entries_count;
    uint32_t sectors = (size) / g_boot_sector.bytes_per_sector;
    if (size % g_boot_sector.bytes_per_sector > 0)
        sectors++;

    g_root_directory_end = lba + sectors;
    g_root_directory = (directory_entry *)malloc(sectors * g_boot_sector.bytes_per_sector);
    return read_sectors(disk, lba, sectors, g_root_directory);
}

directory_entry *find_file(const char *name)
{
    for (uint32_t i = 0; i < g_boot_sector.directory_entries_count; i++)
    {
        if (memcmp(name, g_root_directory[i].name, 11) == 0)
        {
            return &g_root_directory[i];
        }
    }

    return NULL;
}

bool read_file(directory_entry *file_entry, FILE *disk, uint8_t *output_buffer)
{
    bool ok = true;
    uint16_t current_cluster = file_entry->first_cluster_low;

    do
    {
        uint32_t lba = g_root_directory_end + (current_cluster - 2) * g_boot_sector.sectors_per_cluster;
        ok = ok && read_sectors(disk, lba, g_boot_sector.sectors_per_cluster, output_buffer);
        output_buffer += g_boot_sector.sectors_per_cluster * g_boot_sector.bytes_per_sector;

        uint32_t fat_index = current_cluster * 3 / 2;
        if (current_cluster % 2 == 0)
            current_cluster = (*(uint16_t *)(g_fat + fat_index)) & 0x0FFF;
        else
            current_cluster = (*(uint16_t *)(g_fat + fat_index)) >> 4;
    } while (ok && current_cluster < 0xFF8);

    return ok;
}

int main(int argc, char **argv)
{
    if (argc < 3)
    {
        printf("Syntax: %s: <image file> <file name>\n", argv[0]);
        return -1;
    }

    FILE *disk = fopen(argv[1], "rb");
    if (!disk)
    {
        fprintf(stderr, "Failed to open disk image %s\n", argv[1]);
        return -1;
    }

    if (!read_boot_sector(disk))
    {
        fprintf(stderr, "Failed to read boot sector\n");
        return -2;
    }

    if (!read_fat(disk))
    {
        fprintf(stderr, "Failed to read FAT\n");
        free(g_fat);
        return -3;
    }

    if (!read_root_directory(disk))
    {
        fprintf(stderr, "Failed to read root directory\n");
        free(g_fat);
        free(g_root_directory);
        return -4;
    }

    directory_entry *file_entry = find_file(argv[2]);
    if (!file_entry)
    {
        fprintf(stderr, "File not found: %s\n", argv[2]);
        free(g_fat);
        free(g_root_directory);
        return -5;
    }

    uint8_t *buffer = (uint8_t *)malloc(file_entry->size + g_boot_sector.bytes_per_sector);
    if (!read_file(file_entry, disk, buffer))
    {
        fprintf(stderr, "Failed to read file %s\n", argv[2]);
        free(g_fat);
        free(g_root_directory);
        free(buffer);
        return -6;
    }

    for (size_t i = 0; i < file_entry->size; i++)
    {
        if (isprint(buffer[i]))
            fputc(buffer[i], stdout);
        else
            printf("<%02x>", buffer[i]);
    }

    free(g_fat);
    free(g_root_directory);
    return 0;
}
