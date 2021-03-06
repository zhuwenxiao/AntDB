/*-------------------------------------------------------------------------
 *
 * filemap.h
 *
 * Copyright (c) 2013 VMware, Inc. All Rights Reserved.
 *-------------------------------------------------------------------------
 */
#ifndef FILEMAP_H
#define FILEMAP_H

#include "storage/relfilenode.h"
#include "storage/block.h"

/*
 * For every file found in the local or remote system, we have a file entry
 * which says what we are going to do with the file. For relation files,
 * there is also a page map, marking pages in the file that were changed
 * locally.
 *
 * The enum values are sorted in the order we want actions to be processed.
 */
typedef enum
{
	FILE_ACTION_CREATE,		/* create local directory or symbolic link */
	FILE_ACTION_COPY,		/* copy whole file, overwriting if exists */
	FILE_ACTION_COPY_TAIL,	/* copy tail from 'oldsize' to 'newsize' */
	FILE_ACTION_NONE,		/* no action (we might still copy modified blocks
							 * based on the parsed WAL) */
	FILE_ACTION_TRUNCATE,	/* truncate local file to 'newsize' bytes */
	FILE_ACTION_REMOVE,		/* remove local file / directory / symlink */

} file_action_t;

typedef enum
{
	FILE_TYPE_REGULAR,
	FILE_TYPE_DIRECTORY,
	FILE_TYPE_SYMLINK
} file_type_t;

struct file_entry_t
{
	char	   *path;
	file_type_t type;

	file_action_t action;

	/* for a regular file */
	size_t		oldsize;
	size_t		newsize;
	bool		isrelfile;		/* is it a relation data file? */

	datapagemap_t	pagemap;

	/* for a symlink */
	char		*link_target;

	struct file_entry_t *next;
};

typedef struct file_entry_t file_entry_t;

struct filemap_t
{
	/*
	 * New entries are accumulated to a linked list, in process_remote_file
	 * and process_local_file.
	 */
	file_entry_t *first;
	file_entry_t *last;
	int			nlist;

	/*
	 * After processing all the remote files, the entries in the linked list
	 * are moved to this array. After processing local file, too, all the
	 * local entries are added to the array by filemap_finalize, and sorted
	 * in the final order. After filemap_finalize, all the entries are in
	 * the array, and the linked list is empty.
	 */
	file_entry_t **array;
	int			narray;
};

typedef struct filemap_t filemap_t;

extern filemap_t * filemap;

extern filemap_t *filemap_create(void);

extern void print_filemap(void);

/* Functions for populating the filemap */
extern void process_remote_file(const char *path, file_type_t type, size_t newsize, const char *link_target);
extern void process_local_file(const char *path, file_type_t type, size_t newsize, const char *link_target);
extern void process_block_change(ForkNumber forknum, RelFileNode rnode, BlockNumber blkno);
extern void filemap_finalize(void);

#endif   /* FILEMAP_H */
