%{

#include "postgres.h"

#include "nodes/makefuncs.h"
#include "nodes/parsenodes.h"
#include "nodes/value.h"
#include "nodes/pg_list.h"
#include "parser/mgr_node.h"
#include "parser/parser.h"
#include "parser/scanner.h"
#include "catalog/mgr_cndnnode.h"
#include "catalog/mgr_parm.h"
#include "catalog/mgr_updateparm.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/syscache.h"
#include "utils/tqual.h"
#include "utils/fmgroids.h"    /* For F_NAMEEQ	*/
#include "access/htup_details.h"
#include "catalog/indexing.h"
#include "catalog/mgr_host.h"
#include "catalog/monitor_job.h"
#include "catalog/monitor_jobitem.h"
#include "catalog/pg_type.h"
#include "commands/defrem.h"
#include "funcapi.h"
#include "libpq/ip.h"
#include "mgr/mgr_agent.h"
#include "mgr/mgr_cmds.h"
#include "mgr/mgr_msg_type.h"
#include "miscadmin.h"
#include "nodes/parsenodes.h"
#include "parser/mgr_node.h"
/*
 * The YY_EXTRA data that a flex scanner allows us to pass around.  Private
 * state needed for raw parsing/lexing goes here.
 */
typedef struct mgr_yy_extra_type
{
	/*
	 * Fields used by the core scanner.
	 */
	core_yy_extra_type core_yy_extra;

	/*
	 * State variables that belong to the grammar.
	 */
	List	   *parsetree;		/* final parse result is delivered here */
} mgr_yy_extra_type;

/*
 * In principle we should use yyget_extra() to fetch the yyextra field
 * from a yyscanner struct.  However, flex always puts that field first,
 * and this is sufficiently performance-critical to make it seem worth
 * cheating a bit to use an inline macro.
 */
#define mgr_yyget_extra(yyscanner) (*((mgr_yy_extra_type **) (yyscanner)))

/*
 * Location tracking support --- simpler than bison's default, since we only
 * want to track the start position not the end position of each nonterminal.
 */
#define YYLLOC_DEFAULT(Current, Rhs, N) \
	do { \
		if ((N) > 0) \
			(Current) = (Rhs)[1]; \
		else \
			(Current) = (-1); \
	} while (0)

#define YYMALLOC palloc
#define YYFREE   pfree

#define parser_yyerror(msg)  scanner_yyerror(msg, yyscanner)
#define parser_errposition(pos)  scanner_errposition(pos, yyscanner)

#define GTM_TYPE          'G'
#define COORDINATOR_TYPE  'C'
#define DATANODE_TYPE     'D'

union YYSTYPE;					/* need forward reference for tok_is_keyword */
static void mgr_yyerror(YYLTYPE *yylloc, core_yyscan_t yyscanner,
						 const char *msg);
static int mgr_yylex(union YYSTYPE *lvalp, YYLTYPE *llocp,
		   core_yyscan_t yyscanner);
List *mgr_parse_query(const char *query_string);
static Node* make_column_in(const char *col_name, List *values);
static Node* makeNode_RangeFunction(const char *func_name, List *func_args);
static Node* make_func_call(const char *func_name, List *func_args);
/* static List* make_start_agent_args(List *options); */
extern char *defGetString(DefElem *def);
static Node* make_ColumnRef(const char *col_name);
static Node* make_whereClause_for_datanode(char* node_type_str, List* node_name_list, char* like_expr);
static Node* make_whereClause_for_coord(char * node_type_str, List* node_name_list, char* like_expr);
static Node* make_whereClause_for_gtm(char * node_type_str, List* node_name_list, char* like_expr);
static void check_node_name_isvaild(char node_type, List* node_name_list);
static void check__name_isvaild(List *node_name_list);
static void check_host_name_isvaild(List *node_name_list);
static void check_job_name_isvaild(List *node_name_list);
static void check_jobitem_name_isvaild(List *node_name_list);
%}

%pure-parser
%expect 0
%name-prefix="mgr_yy"
%locations

%parse-param {core_yyscan_t yyscanner}
%lex-param   {core_yyscan_t yyscanner}

%union
{
	core_YYSTYPE		core_yystype;
	/* these fields must match core_YYSTYPE: */
	int					ival;
	char				*str;
	const char			*keyword;

	char				chr;
	DefElem				*defelt;
	bool				boolean;
	List				*list;
	Node				*node;
	VariableSetStmt		*vsetstmt;
	Value				*value;
}

/*
 * Non-keyword token types.  These are hard-wired into the "flex" lexer.
 * They must be listed first so that their numeric codes do not depend on
 * the set of keywords.  PL/pgsql depends on this so that it can share the
 * same lexer.  If you add/change tokens here, fix PL/pgsql to match!
 *
 * DOT_DOT is unused in the core SQL grammar, and so will always provoke
 * parse errors.  It is needed by PL/pgsql.
 */
%token <str>	IDENT FCONST SCONST BCONST XCONST Op
%token <ival>	ICONST 
%token			TYPECAST DOT_DOT COLON_EQUALS

%type <list>	stmtblock stmtmulti
%type <node>	stmt
%type <node>	AddHostStmt DropHostStmt ListHostStmt AlterHostStmt
				ListParmStmt StartAgentStmt AddNodeStmt StopAgentStmt
				DropNodeStmt AlterNodeStmt ListNodeStmt InitNodeStmt 
				VariableSetStmt StartNodeMasterStmt StopNodeMasterStmt
				MonitorStmt FailoverStmt /* ConfigAllStmt */DeploryStmt
				Gethostparm ListMonitor Gettopologyparm Update_host_config_value
				Get_host_threshold Get_alarm_info AppendNodeStmt
				AddUpdataparmStmt CleanAllStmt ResetUpdataparmStmt ShowStmt FlushHost
				AddHbaStmt DropHbaStmt ListHbaStmt ListAclStmt
				CreateUserStmt DropUserStmt GrantStmt privilege username hostname
				AlterUserStmt AddJobitemStmt AlterJobitemStmt DropJobitemStmt ListJobStmt
				AddExtensionStmt DropExtensionStmt RemoveNodeStmt FailoverManualStmt SwitchoverStmt

%type <list>	general_options opt_general_options general_option_list HbaParaList
				AConstList targetList ObjList var_list NodeConstList set_parm_general_options
				OptRoleList name_list privilege_list username_list hostname_list
				AlterOptRoleList

%type <node>	general_option_item general_option_arg target_el
%type <node> 	var_value

%type <defelt>	CreateOptRoleElem AlterOptRoleElem

%type <ival>	Iconst SignedIconst opt_gtm_inner_type opt_dn_inner_type opt_general_force 
							opt_slave_inner_type
%type <vsetstmt> set_rest set_rest_more
%type <value>	NumericOnly

%type <keyword>	unreserved_keyword reserved_keyword
%type <str>		Ident SConst ColLabel var_name opt_boolean_or_string
				NonReservedWord NonReservedWord_or_Sconst set_ident
				opt_password opt_stop_mode
				opt_general_all var_dotparam var_showparam
				sub_like_expr RoleId name ColId

%type <chr>		node_type cluster_type

%token<keyword>	ADD_P DEPLOY DROP ALTER LIST CREATE ACL CLUSTER
%token<keyword>	IF_P EXISTS NOT
%token<keyword>	FALSE_P TRUE_P
%token<keyword>	HOST MONITOR PARAM HBA HA
%token<keyword>	INIT GTM MASTER SLAVE EXTRA ALL NODE COORDINATOR DATANODE
%token<keyword> PASSWORD CLEAN RESET WHERE ROW_ID
%token<keyword> START AGENT STOP FAILOVER
%token<keyword> SET TO ON OFF
%token<keyword> APPEND CONFIG MODE FAST SMART IMMEDIATE S I F FORCE SHOW FLUSH
%token<keyword> GRANT REVOKE FROM ITEM JOB EXTENSION REMOVE DATA_CHECKSUMS
%token<keyword> STATUS ACTIVATE
%token<keyword> PROMOTE ADBMGR REWIND SWITCHOVER

/* for ADB monitor*/
%token<keyword> GET_HOST_LIST_ALL GET_HOST_LIST_SPEC
				GET_HOST_HISTORY_USAGE
				GET_HOST_HISTORY_USAGE_BY_TIME_PERIOD
				GET_ALL_NODENAME_IN_SPEC_HOST
				GET_AGTM_NODE_TOPOLOGY GET_COORDINATOR_NODE_TOPOLOGY GET_DATANODE_NODE_TOPOLOGY
				GET_CLUSTER_SUMMARY GET_DATABASE_TPS_QPS GET_CLUSTER_HEADPAGE_LINE
				GET_DATABASE_TPS_QPS_INTERVAL_TIME MONITOR_DATABASETPS_FUNC_BY_TIME_PERIOD
				GET_DATABASE_SUMMARY GET_SLOWLOG GET_USER_INFO UPDATE_USER GET_SLOWLOG_COUNT
				UPDATE_THRESHOLD_VALUE UPDATE_PASSWORD CHECK_USER USER
				GET_THRESHOLD_TYPE GET_THRESHOLD_ALL_TYPE CHECK_PASSWORD GET_DB_THRESHOLD_ALL_TYPE
				GET_ALARM_INFO_ASC GET_ALARM_INFO_DESC RESOLVE_ALARM GET_ALARM_INFO_COUNT
				GET_CLUSTER_TPS_QPS GET_CLUSTER_CONNECT_DBSIZE_INDEXSIZE
%%
/*
 *	The target production for the whole parse.
 */
stmtblock:	stmtmulti
			{
				mgr_yyget_extra(yyscanner)->parsetree = $1;
			}
		;

/* the thrashing around here is to discard "empty" statements... */
stmtmulti:	stmtmulti ';' stmt
				{
					if ($3 != NULL)
						$$ = lappend($1, $3);
					else
						$$ = $1;
				}
			| stmt
				{
					if ($1 != NULL)
						$$ = list_make1($1);
					else
						$$ = NIL;
				}
		;

stmt :
	  AddHostStmt
	| AlterUserStmt
	| CreateUserStmt
	| DropUserStmt
	| DropHostStmt
	| ListHostStmt
	| AlterHostStmt
	| StartAgentStmt
	| StopAgentStmt
	| ListAclStmt
	| ListMonitor
	| ListParmStmt
	| AddNodeStmt
	| AlterNodeStmt
	| DropNodeStmt
	| ListNodeStmt
	| MonitorStmt
	| VariableSetStmt
	| InitNodeStmt
	| StartNodeMasterStmt
	| StopNodeMasterStmt
	| FailoverStmt
	/* | ConfigAllStmt */
	| DeploryStmt
	| Gethostparm     /* for ADB monitor host page */
	| Gettopologyparm /* for ADB monitor home page */
	| Update_host_config_value
	| Get_host_threshold
	| GrantStmt
	| Get_alarm_info
	| AppendNodeStmt
	| AddUpdataparmStmt
	| ResetUpdataparmStmt
	| CleanAllStmt
	| ShowStmt
	| FlushHost
	| AddHbaStmt
	| DropHbaStmt
	| ListHbaStmt
	|	AddJobitemStmt
	|	AlterJobitemStmt
	|	DropJobitemStmt
	|	ListJobStmt
	| AddExtensionStmt
	| DropExtensionStmt
	| RemoveNodeStmt
	| FailoverManualStmt
	| SwitchoverStmt
	| /* empty */
		{ $$ = NULL; }
	;

AlterUserStmt:
			ALTER USER RoleId AlterOptRoleList
				 {
					AlterRoleStmt *n = makeNode(AlterRoleStmt);
					n->role = $3;
					n->action = +1; /* add, if there are members */
					n->options = $4;
					$$ = (Node *)n;
				 }
			;

GrantStmt:
		GRANT privilege_list TO username_list
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *command_type = makeIntConst(PRIV_GRANT, -1);
			Node *privs = makeAArrayExpr($2, @2);
			Node *names = makeAArrayExpr($4, @4);
			List *args = list_make3(command_type, privs, names);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_priv_manage", args));
			$$ = (Node*)stmt;
		}
		| GRANT ALL TO username_list
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *command_type = makeIntConst(PRIV_GRANT, -1);
			Node *names = makeAArrayExpr($4, @4);
			List *args = list_make2(command_type, names);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_priv_all_to_username", args));
			$$ = (Node*)stmt;
		}
		| GRANT privilege_list TO ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *command_type = makeIntConst(PRIV_GRANT, -1);
			Node *privs = makeAArrayExpr($2, @2);
			List *args = list_make2(command_type, privs);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_priv_list_to_all", args));
			$$ = (Node*)stmt;
		}
		| REVOKE privilege_list FROM username_list
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *command_type = makeIntConst(PRIV_REVOKE, -1);
			Node *privs = makeAArrayExpr($2, @2);
			Node *names = makeAArrayExpr($4, @4);
			List *args = list_make3(command_type, privs, names);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_priv_manage", args));
			$$ = (Node*)stmt;
		}
		| REVOKE ALL FROM username_list
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *command_type = makeIntConst(PRIV_REVOKE, -1);
			Node *names = makeAArrayExpr($4, @4);
			List *args = list_make2(command_type, names);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_priv_all_to_username", args));
			$$ = (Node*)stmt;
		}
		| REVOKE privilege_list FROM ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *command_type = makeIntConst(PRIV_REVOKE, -1);
			Node *privs = makeAArrayExpr($2, @2);
			List *args = list_make2(command_type, privs);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_priv_list_to_all", args));
			$$ = (Node*)stmt;
		}
		;

privilege_list:
			privilege
				{ $$ = list_make1($1); }
			| privilege_list ',' privilege
				{ $$ = lappend($1, $3); }
			;

privilege : IDENT { $$ = makeStringConst(pstrdup($1), @1); };
			| unreserved_keyword { $$ = makeStringConst(pstrdup($1), @1); }
			;

username_list:
			username
				{ $$ = list_make1($1); }
			| username_list ',' username
				{ $$ = lappend($1, $3); }
			;

username : IDENT { $$ = makeStringConst(pstrdup($1), @1); };

DropUserStmt:
			DROP USER name_list
				{
					DropRoleStmt *n = makeNode(DropRoleStmt);
					n->missing_ok = FALSE;
					n->roles = $3;
					$$ = (Node *)n;
				}
			;

name_list:
		name { $$ = list_make1(makeString($1)); }
		| name_list ',' name
			{ $$ = lappend($1, makeString($3)); }
		;

name: ColId     { $$ = $1; };

ColId: IDENT     { $$ = $1; };

CreateUserStmt:
			CREATE USER RoleId OptRoleList
				{
					CreateRoleStmt *n = makeNode(CreateRoleStmt);
					n->stmt_type = ROLESTMT_USER;
					n->role = $3;
					n->options = $4;
					$$ = (Node *)n;
				}
			;

OptRoleList:
			OptRoleList CreateOptRoleElem     { $$ = lappend($1, $2); }
			| /* EMPTY */                     { $$ = NIL; }
			;

AlterOptRoleList:
			AlterOptRoleElem  { $$ = list_make1($1); }
			;

CreateOptRoleElem:
			AlterOptRoleElem  { $$ = $1; }
			;

AlterOptRoleElem:
			PASSWORD SConst
				{
					$$ = makeDefElem("password", (Node *)makeString($2));
				}
				;

/*			| IDENT
 *				{
 *					if (strcmp($1, "superuser") == 0)
 *						$$ = makeDefElem("superuser", (Node *)makeInteger(TRUE));
 *					else if (strcmp($1, "nosuperuser") == 0)
 *						$$ = makeDefElem("superuser", (Node *)makeInteger(FALSE));
 *					else
 *						ereport(ERROR,
 *								(errcode(ERRCODE_SYNTAX_ERROR),
 *								 errmsg("unrecognized role option \"%s\"", $1),
 *									parser_errposition(@1)));
 *				}
 */

AppendNodeStmt:
		APPEND DATANODE MASTER Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_dnmaster", args));
			with_data_checksums = false;
			$$ = (Node*)stmt;
		}
		|	APPEND DATANODE MASTER Ident DATA_CHECKSUMS
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_dnmaster", args));
			with_data_checksums = true;
			$$ = (Node*)stmt;
		}
		| APPEND DATANODE SLAVE Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_dnslave", args));
			$$ = (Node*)stmt;
		}
		| APPEND DATANODE EXTRA Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_dnextra", args));
			$$ = (Node*)stmt;
		}
		| APPEND COORDINATOR Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_coordmaster", args));
			with_data_checksums = false;
			$$ = (Node*)stmt;
		}
		| APPEND COORDINATOR Ident DATA_CHECKSUMS
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_coordmaster", args));
			with_data_checksums = true;
			$$ = (Node*)stmt;
		}
		| APPEND GTM SLAVE Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_agtmslave", args));
			$$ = (Node*)stmt;
		}
		| APPEND GTM EXTRA Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_agtmextra", args));
			$$ = (Node*)stmt;
		}
		|APPEND COORDINATOR Ident TO Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args, makeStringConst($5, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_coord_to_coord", args));
			$$ = (Node*)stmt;
		}
		|APPEND ACTIVATE COORDINATOR Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_append_activate_coord", args));
			$$ = (Node*)stmt;
		}
		;

Get_alarm_info:
		GET_ALARM_INFO_ASC '(' Ident ',' Ident ',' SConst ',' SignedIconst ',' SignedIconst ',' SignedIconst ',' SignedIconst ',' SignedIconst ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args,makeStringConst($5, -1));
			args = lappend(args, makeStringConst($7, -1));
			args = lappend(args, makeIntConst($9, -1));
			args = lappend(args, makeIntConst($11, -1));
			args = lappend(args, makeIntConst($13, -1));
			args = lappend(args, makeIntConst($15, -1));
			args = lappend(args, makeIntConst($17, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("get_alarm_info_asc", args));
			$$ = (Node*)stmt;
		}
		| GET_ALARM_INFO_DESC '(' Ident ',' Ident ',' SConst ',' SignedIconst ',' SignedIconst ',' SignedIconst ',' SignedIconst ',' SignedIconst ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args,makeStringConst($5, -1));
			args = lappend(args, makeStringConst($7, -1));
			args = lappend(args, makeIntConst($9, -1));
			args = lappend(args, makeIntConst($11, -1));
			args = lappend(args, makeIntConst($13, -1));
			args = lappend(args, makeIntConst($15, -1));
			args = lappend(args, makeIntConst($17, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("get_alarm_info_desc", args));
			$$ = (Node*)stmt;
		}
		| GET_ALARM_INFO_COUNT '(' Ident ',' Ident ',' SConst ',' SignedIconst ',' SignedIconst ',' SignedIconst ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args,makeStringConst($5, -1));
			args = lappend(args, makeStringConst($7, -1));
			args = lappend(args, makeIntConst($9, -1));
			args = lappend(args, makeIntConst($11, -1));
			args = lappend(args, makeIntConst($13, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("get_alarm_info_count", args));
			$$ = (Node*)stmt;
		} 
		|RESOLVE_ALARM '(' SignedIconst ',' Ident ',' Ident ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, -1));
			args = lappend(args,makeStringConst($5, -1));
			args = lappend(args,makeStringConst($7, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("resolve_alarm", args));
			$$ = (Node*)stmt;
		};

Gettopologyparm:
        GET_AGTM_NODE_TOPOLOGY
        {
            SelectStmt *stmt = makeNode(SelectStmt);
            stmt->targetList = list_make1(make_star_target(-1));
            stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("get_agtm_node_topology"), -1));
            $$ = (Node*)stmt;
        }
        | GET_COORDINATOR_NODE_TOPOLOGY
        {
            SelectStmt *stmt = makeNode(SelectStmt);
            stmt->targetList = list_make1(make_star_target(-1));
            stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("get_coordinator_node_topology"), -1));
            $$ = (Node*)stmt;
        }
        | GET_DATANODE_NODE_TOPOLOGY
        {
            SelectStmt *stmt = makeNode(SelectStmt);
            stmt->targetList = list_make1(make_star_target(-1));
            stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("get_datanode_node_topology"), -1));
            $$ = (Node*)stmt;
        };

Gethostparm:
		GET_HOST_LIST_ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("get_all_host_parm"), -1));
			$$ = (Node*)stmt;
		}
		| GET_HOST_LIST_SPEC '(' AConstList ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("get_spec_host_parm"), -1));
			stmt->whereClause = make_column_in("hostname", $3);
			$$ = (Node*)stmt;
		}
		| GET_HOST_HISTORY_USAGE '(' Ident ',' SignedIconst ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args, makeIntConst($5, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("get_host_history_usage", args));
			$$ = (Node*)stmt;
		}
		| GET_HOST_HISTORY_USAGE_BY_TIME_PERIOD '(' Ident ',' Ident ',' Ident ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args, makeStringConst($5, -1));
			args = lappend(args, makeStringConst($7, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("get_host_history_usage_by_time_period", args));
			$$ = (Node*)stmt;
		}
        | GET_ALL_NODENAME_IN_SPEC_HOST '(' Ident ')'
        {
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("get_all_nodename_in_spec_host", args));
			$$ = (Node*)stmt;
        };

Update_host_config_value:
		UPDATE_THRESHOLD_VALUE '(' SignedIconst ',' SignedIconst ',' SignedIconst ',' SignedIconst')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, -1));
			args = lappend(args, makeIntConst($5, -1));
			args = lappend(args, makeIntConst($7, -1));
			args = lappend(args, makeIntConst($9, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("update_threshold_value", args));
			$$ = (Node*)stmt;
		};

Get_host_threshold:
		GET_THRESHOLD_TYPE '(' SignedIconst ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("get_threshold_type", args));
			$$ = (Node*)stmt;
		}
		| GET_THRESHOLD_ALL_TYPE
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("get_threshold_all_type"), -1));
			$$ = (Node*)stmt;
		}
		|	GET_DB_THRESHOLD_ALL_TYPE
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("get_db_threshold_all_type"), -1));
			$$ = (Node*)stmt;
		}
		;

/*ConfigAllStmt:
*		CONFIG ALL
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_configure_nodes_all", NULL));
*			$$ = (Node*)stmt;
*		}
*	;
*/

MonitorStmt:
		MONITOR opt_general_all
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("monitor_all"), -1));
			$$ = (Node*)stmt;
		}
		| MONITOR GTM opt_general_all
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_monitor_gtm_all", NULL));
			$$ = (Node*)stmt;
		}
		| MONITOR DATANODE opt_general_all
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_monitor_datanode_all", NULL));
			$$ = (Node*)stmt;
		}
		| MONITOR node_type NodeConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = lcons(makeIntConst($2, @2), $3);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_monitor_nodetype_namelist", args));
			$$ = (Node*)stmt;
		}
		| MONITOR node_type opt_general_all
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *arg = list_make1(makeIntConst($2,-1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_monitor_nodetype_all", arg));
			$$ = (Node*)stmt;
		}
		| MONITOR AGENT opt_general_all
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_monitor_agent_all", NULL));
			$$ = (Node*)stmt;
		}
		| MONITOR AGENT hostname_list
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *hostnames = makeAArrayExpr($3, @3);
			List *arg = list_make1(hostnames);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_monitor_agent_hostlist", arg));
			$$ = (Node*)stmt;
		}
		| MONITOR HA
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("ha"), -1));
			$$ = (Node*)stmt;
		}
		| MONITOR HA '(' targetList ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = $4;
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("ha"), -1));
			$$ = (Node*)stmt;
		}
	| MONITOR HA AConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("ha"), -1));
			stmt->whereClause = make_column_in("nodename", $3);
			$$ = (Node*)stmt;
			check__name_isvaild($3);
		}
	| MONITOR HA'(' targetList ')' AConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = $4;
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("ha"), -1));
			stmt->whereClause = make_column_in("nodename", $6);
			$$ = (Node*)stmt;
			check__name_isvaild($6);
		}
	;

hostname_list:
			hostname
				{ $$ = list_make1($1); }
			| hostname_list ',' hostname
				{ $$ = lappend($1, $3); }
			;

hostname : IDENT { $$ = makeStringConst(pstrdup($1), @1); };

node_type:
		DATANODE MASTER			{$$ = CNDN_TYPE_DATANODE_MASTER;}
		| DATANODE SLAVE		{$$ = CNDN_TYPE_DATANODE_SLAVE;}
		| DATANODE EXTRA		{$$ = CNDN_TYPE_DATANODE_EXTRA;}
		| COORDINATOR			{$$ = CNDN_TYPE_COORDINATOR_MASTER;}
		| GTM MASTER			{$$ = GTM_TYPE_GTM_MASTER;}
		| GTM SLAVE				{$$ = GTM_TYPE_GTM_SLAVE;}
		| GTM EXTRA				{$$ = GTM_TYPE_GTM_EXTRA;}
		;

opt_general_all:
		ALL 		{ $$ = pstrdup("all"); }
		| /*empty */{ $$ = pstrdup("all"); }
		;

VariableSetStmt:
			SET set_rest
				{
					VariableSetStmt *n = $2;
					n->is_local = false;
					$$ = (Node *) n;
				}
			;
			
set_rest: set_rest_more { $$ = $1; };

set_rest_more:
			var_name TO var_list
				{
					VariableSetStmt *n = makeNode(VariableSetStmt);
					n->kind = VAR_SET_VALUE;
					n->name = $1;
					n->args = $3;
					$$ = n;
				}
			| var_name '=' var_list
				{
					VariableSetStmt *n = makeNode(VariableSetStmt);
					n->kind = VAR_SET_VALUE;
					n->name = $1;
					n->args = $3;
					$$ = n;
				}
			;

var_name:	IDENT									{ $$ = $1; }
			| var_name '.' IDENT
				{
					$$ = palloc(strlen($1) + strlen($3) + 2);
					sprintf($$, "%s.%s", $1, $3);
				}
			;
var_dotparam:
			Ident '.' Ident
				{
					$$ = palloc(strlen($1) + strlen($3) + 2);
					sprintf($$, "%s.%s", $1, $3);
				}
			;
var_showparam:
			Ident							{ $$ = $1; }
			| var_dotparam					{ $$ = $1; }
			;
var_list:	var_value								{ $$ = list_make1($1); }
			| var_list ',' var_value				{ $$ = lappend($1, $3); }
			;

var_value:	opt_boolean_or_string  	{ $$ = makeStringConst($1, @1); }
			| NumericOnly    		{ $$ = makeAConst($1, @1); }
			;
opt_boolean_or_string:
			TRUE_P									{ $$ = "true"; }
			| FALSE_P								{ $$ = "false"; }
			| ON									{ $$ = "on"; }
			/*
			 * OFF is also accepted as a boolean value, but is handled by
			 * the NonReservedWord rule.  The action for booleans and strings
			 * is the same, so we don't need to distinguish them here.
			 */
			| NonReservedWord_or_Sconst				{ $$ = $1; }
			;
			
NonReservedWord_or_Sconst:
			NonReservedWord							{ $$ = $1; }
			| SConst								{ $$ = $1; }
			;

RoleId:		NonReservedWord							{ $$ = $1; };

NonReservedWord:	IDENT							{ $$ = $1; }
			| unreserved_keyword					{ $$ = pstrdup($1); }
			;			
			
NumericOnly:
			FCONST								{ $$ = makeFloat($1); }
			| '-' FCONST
				{
					$$ = makeFloat($2);
					doNegateFloat($$);
				}
			| SignedIconst						{ $$ = makeInteger($1); }
			;

AddHostStmt:
	  ADD_P HOST Ident opt_general_options
		{
			MGRAddHost *node = makeNode(MGRAddHost);
			node->if_not_exists = false;
			node->name = $3;
			node->options = $4;
			$$ = (Node*)node;
		}
	| ADD_P HOST IF_P NOT EXISTS Ident opt_general_options
		{
			MGRAddHost *node = makeNode(MGRAddHost);
			node->if_not_exists = true;
			node->name = $6;
			node->options = $7;
			$$ = (Node*)node;
		}
	;

opt_general_options:
	  general_options	{ $$ = $1; }
	| /* empty */		{ $$ = NIL; }
	;

set_parm_general_options:
	  general_options	{ $$ = $1; }
	;
	
general_options: '(' general_option_list ')'
		{
			$$ = $2;
		}
	;

general_option_list:
	  general_option_item
		{
			$$ = list_make1($1);
		}
	| general_option_list ',' general_option_item
		{
			$$ = lappend($1, $3);
		}
	;

general_option_item:
	  ColLabel general_option_arg		{ $$ = (Node*)makeDefElem($1, $2); }
	| ColLabel '=' general_option_arg	{ $$ = (Node*)makeDefElem($1, $3); }
	| ColLabel 							{ $$ = (Node*)makeDefElem($1, NULL); }
	| var_dotparam						{ $$ = (Node*)makeDefElem($1, NULL); }
	| var_dotparam '=' general_option_arg { $$ = (Node*)makeDefElem($1, $3); }

	;
/*conntype database role addr auth_method*/
	
general_option_arg:
	  Ident								{ $$ = (Node*)makeString($1); }
	| SConst							{ $$ = (Node*)makeString($1); }
	| SignedIconst						{ $$ = (Node*)makeInteger($1); }
	| FCONST							{ $$ = (Node*)makeFloat($1); }
	| reserved_keyword					{ $$ = (Node*)makeString(pstrdup($1)); }
	;

DropHostStmt:
	  DROP HOST ObjList
		{
			MGRDropHost *node = makeNode(MGRDropHost);
			node->if_exists = false;
			node->hosts = $3;
			$$ = (Node*)node;
		}
	| DROP HOST IF_P EXISTS ObjList
		{
			MGRDropHost *node = makeNode(MGRDropHost);
			node->if_exists = true;
			node->hosts = $5;
			$$ = (Node*)node;
		}
	;

ObjList:
	  ObjList ',' Ident
		{
			$$ = lappend($1, makeString($3));
		}
	| Ident
		{
			$$ = list_make1(makeString($1));
		}
	;	

ListHostStmt:
	  LIST HOST
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("host"), -1));
			$$ = (Node*)stmt;
		}
	| LIST HOST '(' targetList ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = $4;
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("host"), -1));
			$$ = (Node*)stmt;
		}
	| LIST HOST AConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("host"), -1));
			stmt->whereClause = make_column_in("name", $3);
			$$ = (Node*)stmt;

			check_host_name_isvaild($3);
		}
	| LIST HOST '(' targetList ')' AConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = $4;
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("host"), -1));
			stmt->whereClause = make_column_in("name", $6);
			$$ = (Node*)stmt;

			check_host_name_isvaild($6);
		}
	;

AConstList:
	  AConstList ',' Ident	{ $$ = lappend($1, makeAConst(makeString($3), @3)); }
	| Ident						{ $$ = list_make1(makeAConst(makeString($1), @1)); }
	;
NodeConstList:
	  NodeConstList ',' Ident	{ $$ = lappend($1, makeStringConst($3, @3)); }
	| Ident						{ $$ = list_make1(makeStringConst($1, @1)); }
	;
targetList:
	  targetList ',' target_el	{ $$ = lappend($1, $3); }
	| target_el					{ $$ = list_make1($1); }
	;

target_el:
	  Ident
		{
			ResTarget *target = makeNode(ResTarget);
			ColumnRef *col = makeNode(ColumnRef);
			col->fields = list_make1(makeString($1));
			col->location = @1;
			target->val = (Node*)col;
			target->location = @1;
			$$ = (Node*)target;
		}
	| '*'
		{
			$$ = (Node*)make_star_target(@1);
		}
	;

Ident:
	  IDENT					{ $$ = $1; }
	| unreserved_keyword	{ $$ = pstrdup($1); }
	;
set_ident:
	 Ident					{ $$ = $1; }
	|	ALL					{ $$ = pstrdup("*"); }
	;
SConst: SCONST				{ $$ = $1; }
Iconst: ICONST				{ $$ = $1; }

SignedIconst: Iconst								{ $$ = $1; }
			| '+' Iconst							{ $$ = + $2; }
			| '-' Iconst							{ $$ = - $2; }
		;

ColLabel:	IDENT									{ $$ = $1; }
			| unreserved_keyword					{ $$ = pstrdup($1); }
			| reserved_keyword						{ $$ = pstrdup($1); }
		;

AlterHostStmt:
        ALTER HOST Ident opt_general_options
		{
			MGRAlterHost *node = makeNode(MGRAlterHost);
			node->if_not_exists = false;
			node->name = $3;
			node->options = $4;
			$$ = (Node*)node;
		}
	;

StartAgentStmt:
		START AGENT ALL opt_password
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_agent_all", args));
			$$ = (Node*)stmt;
		}
		| START AGENT hostname_list opt_password
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *password = makeStringConst($4, -1);
			Node *hostnames = makeAArrayExpr($3, @3);
			List *args = list_make2(password, hostnames);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_agent_hostnamelist", args));
			$$ = (Node*)stmt;
		}
		;

StopAgentStmt:
		STOP AGENT ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_agent_all", NULL));
			$$ = (Node*)stmt;
		}
		| STOP AGENT hostname_list
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *hostnames = makeAArrayExpr($3, @3);
			List *arg = list_make1(hostnames);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_agent_hostnamelist", arg));
			$$ = (Node*)stmt;
		}
		;

/* parm start*/
AddUpdataparmStmt:
		SET GTM opt_gtm_inner_type Ident set_parm_general_options
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_GTM;
				node->nodetype = $3;
				node->nodename = $4;
				node->options = $5;
				node->is_force = false;
				$$ = (Node*)node;
		}
	|	SET GTM opt_gtm_inner_type Ident set_parm_general_options FORCE
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_GTM;
				node->nodetype = $3;
				node->nodename = $4;
				node->options = $5;
				node->is_force= true;
				$$ = (Node*)node;
		}
	|	SET GTM ALL set_parm_general_options
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_GTM;
				node->nodetype = CNDN_TYPE_GTM;
				node->nodename = MACRO_STAND_FOR_ALL_NODENAME;
				node->options = $4;
				node->is_force = false;
				$$ = (Node*)node;
		}
	|	SET GTM ALL set_parm_general_options FORCE
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_GTM;
				node->nodetype = CNDN_TYPE_GTM;
				node->nodename = MACRO_STAND_FOR_ALL_NODENAME;
				node->options = $4;
				node->is_force= true;
				$$ = (Node*)node;
		}
	| SET DATANODE opt_dn_inner_type set_ident set_parm_general_options
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_DATANODE;
				node->nodetype = $3;
				node->nodename = $4;
				node->options = $5;
				node->is_force = false;
				$$ = (Node*)node;
		}
	| SET DATANODE opt_dn_inner_type set_ident set_parm_general_options FORCE
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_DATANODE;
				node->nodetype = $3;
				node->nodename = $4;
				node->options = $5;
				node->is_force = true;
				$$ = (Node*)node;
		}
	| SET DATANODE ALL set_parm_general_options
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_DATANODE;
				node->nodetype = CNDN_TYPE_DATANODE;
				node->nodename = MACRO_STAND_FOR_ALL_NODENAME;
				node->options = $4;
				node->is_force = false;
				$$ = (Node*)node;
		}
	| SET DATANODE ALL set_parm_general_options FORCE
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_DATANODE;
				node->nodetype = CNDN_TYPE_DATANODE;
				node->nodename = MACRO_STAND_FOR_ALL_NODENAME;
				node->options = $4;
				node->is_force = true;
				$$ = (Node*)node;
		}
	| SET COORDINATOR set_ident set_parm_general_options
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_COORDINATOR;
				node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
				node->nodename = $3;
				node->options = $4;
				node->is_force = false;
				$$ = (Node*)node;
		}
	| SET COORDINATOR set_ident set_parm_general_options FORCE
		{
				MGRUpdateparm *node = makeNode(MGRUpdateparm);
				node->parmtype = PARM_TYPE_COORDINATOR;
				node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
				node->nodename = $3;
				node->options = $4;
				node->is_force = true;
				$$ = (Node*)node;
		}
	| SET CLUSTER INIT
		{
			MGRSetClusterInit *node = makeNode(MGRSetClusterInit);
			$$ = (Node*)node;
		}
		;
ResetUpdataparmStmt:
		RESET GTM opt_gtm_inner_type Ident set_parm_general_options
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_GTM;
				node->nodetype = $3;
				node->nodename = $4;
				node->options = $5;
				node->is_force = false;
				$$ = (Node*)node;
		}
	|	RESET GTM opt_gtm_inner_type Ident set_parm_general_options FORCE
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_GTM;
				node->nodetype = $3;
				node->nodename = $4;
				node->options = $5;
				node->is_force = true;
				$$ = (Node*)node;
		}
	| RESET GTM ALL set_parm_general_options
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_GTM;
				node->nodetype = CNDN_TYPE_GTM;
				node->nodename = MACRO_STAND_FOR_ALL_NODENAME;
				node->options = $4;
				node->is_force = false;
				$$ = (Node*)node;
		}
	| RESET GTM ALL set_parm_general_options FORCE
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_GTM;
				node->nodetype = CNDN_TYPE_GTM;
				node->nodename = MACRO_STAND_FOR_ALL_NODENAME;
				node->options = $4;
				node->is_force = true;
				$$ = (Node*)node;
		}
	| RESET DATANODE opt_dn_inner_type set_ident set_parm_general_options
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_DATANODE;
				node->nodetype = $3;
				node->nodename = $4;
				node->options = $5;
				node->is_force = false;
				$$ = (Node*)node;
		}
	| RESET DATANODE opt_dn_inner_type set_ident set_parm_general_options FORCE
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_DATANODE;
				node->nodetype = $3;
				node->nodename = $4;
				node->options = $5;
				node->is_force = true;
				$$ = (Node*)node;
		}
	| RESET DATANODE ALL set_parm_general_options
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_DATANODE;
				node->nodetype = CNDN_TYPE_DATANODE;
				node->nodename = MACRO_STAND_FOR_ALL_NODENAME;
				node->options = $4;
				node->is_force = false;
				$$ = (Node*)node;
		}
	| RESET DATANODE ALL set_parm_general_options FORCE
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_DATANODE;
				node->nodetype = CNDN_TYPE_DATANODE;
				node->nodename = MACRO_STAND_FOR_ALL_NODENAME;
				node->options = $4;
				node->is_force = true;
				$$ = (Node*)node;
		}
	| RESET COORDINATOR set_ident set_parm_general_options
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_COORDINATOR;
				node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
				node->nodename = $3;
				node->options = $4;
				node->is_force = false;
				$$ = (Node*)node;
		}
	| RESET COORDINATOR set_ident set_parm_general_options FORCE
		{
				MGRUpdateparmReset *node = makeNode(MGRUpdateparmReset);
				node->parmtype = PARM_TYPE_COORDINATOR;
				node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
				node->nodename = $3;
				node->options = $4;
				node->is_force = true;
				$$ = (Node*)node;
		}
		;

ListParmStmt:
	  LIST PARAM
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("updateparm"), -1));
			$$ = (Node*)stmt;
		}
	| LIST PARAM node_type Ident sub_like_expr
		{
			StringInfoData like_expr;
			List* node_name;
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("updateparm"), -1));

			node_name = (List*)list_make1(makeStringConst($4, -1));
			check_node_name_isvaild($3, node_name);

			initStringInfo(&like_expr);
			if (strcmp($5, "NULL") == 0)
				appendStringInfo(&like_expr, "%%%%");
			else
				appendStringInfo(&like_expr, "%%%s%%", $5);
			switch ($3)
			{
				case CNDN_TYPE_DATANODE_MASTER:
						stmt->whereClause = make_whereClause_for_datanode("datanode master", node_name, like_expr.data);
						break;
				case CNDN_TYPE_DATANODE_SLAVE:
						stmt->whereClause = make_whereClause_for_datanode("datanode slave", node_name, like_expr.data);
						break;
				case CNDN_TYPE_DATANODE_EXTRA:
						stmt->whereClause = make_whereClause_for_datanode("datanode extra", node_name, like_expr.data);
						break;
				case CNDN_TYPE_COORDINATOR_MASTER:
						stmt->whereClause = make_whereClause_for_coord("coordinator", node_name, like_expr.data);
						break;
				case GTM_TYPE_GTM_MASTER:
						stmt->whereClause = make_whereClause_for_gtm("gtm master", node_name, like_expr.data);
						break;
				case GTM_TYPE_GTM_SLAVE:
						stmt->whereClause = make_whereClause_for_gtm("gtm slave", node_name, like_expr.data);
						break;
				case GTM_TYPE_GTM_EXTRA:
						stmt->whereClause = make_whereClause_for_gtm("gtm extra", node_name, like_expr.data);
						break;
				default:
						break;
			}

			$$ = (Node*)stmt;
		}
	| LIST PARAM cluster_type ALL sub_like_expr
	{
			StringInfoData like_expr;
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("updateparm"), -1));

			initStringInfo(&like_expr);

			if (strcmp($5, "NULL") == 0)
				appendStringInfo(&like_expr, "%%%%");
			else
				appendStringInfo(&like_expr, "%%%s%%", $5);

			switch ($3)
			{
				case GTM_TYPE:
					stmt->whereClause =
						(Node *)(Node *)makeA_Expr(AEXPR_AND, NIL,
							(Node *) makeSimpleA_Expr(AEXPR_OP, "~",
									make_ColumnRef("nodetype"), 
									makeStringConst(pstrdup("gtm"), -1), -1),
							(Node *) makeSimpleA_Expr(AEXPR_OP, "~~",
									make_ColumnRef("key"),
									makeStringConst(pstrdup(like_expr.data), -1), -1),
									-1);
					break;
				case COORDINATOR_TYPE:
					stmt->whereClause =
						(Node *)(Node *)makeA_Expr(AEXPR_AND, NIL,
							(Node *) makeSimpleA_Expr(AEXPR_OP, "~",
									make_ColumnRef("nodetype"),
									makeStringConst(pstrdup("coordinator"), -1), -1),
							(Node *) makeSimpleA_Expr(AEXPR_OP, "~~",
									make_ColumnRef("key"),
									makeStringConst(pstrdup(like_expr.data), -1), -1),
									-1);
					break;
				case DATANODE_TYPE:
					stmt->whereClause =
						(Node *)(Node *)makeA_Expr(AEXPR_AND, NIL,
							(Node *) makeSimpleA_Expr(AEXPR_OP, "~",
									make_ColumnRef("nodetype"),
									makeStringConst(pstrdup("datanode"), -1), -1),
							(Node *) makeSimpleA_Expr(AEXPR_OP, "~~",
									make_ColumnRef("key"),
									makeStringConst(pstrdup(like_expr.data), -1), -1),
									-1);
					break;
				case CNDN_TYPE_DATANODE_MASTER:
					stmt->whereClause =
					(Node *)makeA_Expr(AEXPR_AND, NIL,
						(Node *) makeSimpleA_Expr(AEXPR_OP, "~",
								make_ColumnRef("nodetype"),
								makeStringConst(pstrdup("datanode master"), -1),-1),
						(Node *) makeSimpleA_Expr(AEXPR_OP, "~~",
										make_ColumnRef("key"),
										makeStringConst(pstrdup(like_expr.data), -1), -1),
										-1);
					break;
				case CNDN_TYPE_DATANODE_SLAVE:
					stmt->whereClause =
					(Node *)makeA_Expr(AEXPR_AND, NIL,
						(Node *)makeA_Expr(AEXPR_OR, NIL,
							(Node *) makeSimpleA_Expr(AEXPR_OP, "~",
										make_ColumnRef("nodetype"),
										makeStringConst(pstrdup("datanode slave"), -1),-1),
							(Node *) makeA_Expr(AEXPR_AND, NIL,
								(Node *) makeSimpleA_Expr(AEXPR_OP, "=",
											make_ColumnRef("nodename"),
											makeStringConst(pstrdup("*"), -1), -1),
								(Node *) makeSimpleA_Expr(AEXPR_OP, "~",
											make_ColumnRef("nodetype"),
											makeStringConst(pstrdup("datanode master"), -1), -1),
											-1),-1),
						(Node *)makeSimpleA_Expr(AEXPR_OP, "~~",
								make_ColumnRef("key"),
								makeStringConst(pstrdup(like_expr.data), -1), -1),
								-1);
					break;
				case CNDN_TYPE_DATANODE_EXTRA:
					stmt->whereClause =
					(Node *)makeA_Expr(AEXPR_AND, NIL,
					(Node *)makeA_Expr(AEXPR_OR, NIL,
							(Node *) makeSimpleA_Expr(AEXPR_OP, "~",
										make_ColumnRef("nodetype"),
										makeStringConst(pstrdup("datanode extra"), -1),-1),
							(Node *) makeA_Expr(AEXPR_AND, NIL,
								(Node *) makeSimpleA_Expr(AEXPR_OP, "=",
											make_ColumnRef("nodename"),
											makeStringConst(pstrdup("*"), -1), -1),
								(Node *) makeSimpleA_Expr(AEXPR_OP, "~",
											make_ColumnRef("nodetype"),
											makeStringConst(pstrdup("datanode master"), -1), -1),
											-1),-1),
					(Node *)makeSimpleA_Expr(AEXPR_OP, "~~",
								make_ColumnRef("key"),
								makeStringConst(pstrdup(like_expr.data), -1), -1),
								-1);
					break;
				default:
					break;
			}

			$$ = (Node*)stmt;
	}
	;

/* parm end*/

CleanAllStmt:
		CLEAN ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_clean_all", NULL));
			$$ = (Node*)stmt;
		}
	| CLEAN GTM opt_gtm_inner_type Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, -1));
			args = lappend(args,makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_clean_node", args));
			$$ = (Node*)stmt;
		}
	| CLEAN COORDINATOR NodeConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst(CNDN_TYPE_COORDINATOR_MASTER, -1));
			args = list_concat(args, $3);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_clean_node", args));
			$$ = (Node*)stmt;
		}
	| CLEAN DATANODE opt_dn_inner_type NodeConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, -1));
			args = list_concat(args, $4);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_clean_node", args));
			$$ = (Node*)stmt;
		}
	| CLEAN MONITOR ICONST
		{
			MonitorDeleteData *node = makeNode(MonitorDeleteData);
			node->days = $3;
			$$ = (Node*)node;
		}
	;
/*hba start*/

AddHbaStmt:
	ADD_P HBA set_ident '(' NodeConstList ')'
	{
		SelectStmt *stmt = makeNode(SelectStmt);	
		List *args = lappend($5, makeStringConst($3,@3));
		stmt->targetList = list_make1(make_star_target(-1));
		stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_add_hba", args));
		$$ = (Node*)stmt;
	}
	
DropHbaStmt:
	DROP HBA set_ident HbaParaList 
	{
		SelectStmt *stmt = makeNode(SelectStmt);	
		List *args = lappend($4, makeStringConst($3,@3));		
		stmt->targetList = list_make1(make_star_target(-1));
		stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_drop_hba", args));
		$$ = (Node*)stmt;
	}

ListHbaStmt:
	LIST HBA 
	{
		SelectStmt *stmt = makeNode(SelectStmt);
		stmt->targetList = list_make1(make_star_target(-1));
		stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("hba"), -1));
		$$ = (Node*)stmt;
	}
	| LIST HBA NodeConstList
	{
		SelectStmt *stmt = makeNode(SelectStmt);
		stmt->targetList = list_make1(make_star_target(-1));
		stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_list_hba_by_name", $3));
		$$ = (Node*)stmt;
	}
	
HbaParaList:
	'(' NodeConstList ')' 	{$$ = $2;}
	| /*empty*/             {$$ = NIL;}
	
	
/*hba end*/

/* gtm/coordinator/datanode 
*/
AddNodeStmt:
	  ADD_P GTM opt_gtm_inner_type Ident opt_general_options
		{
			MGRAddNode *node = makeNode(MGRAddNode);
			node->if_not_exists = false;
			node->nodetype = $3; 
			node->name = $4;
			node->options = $5;
			$$ = (Node*)node;
		}
	| ADD_P GTM opt_gtm_inner_type IF_P NOT EXISTS Ident opt_general_options
		{
			MGRAddNode *node = makeNode(MGRAddNode);
			node->if_not_exists = true;
			node->nodetype = $3;
			node->name = $7;
			node->options = $8;
			$$ = (Node*)node;
		}
	| ADD_P COORDINATOR Ident opt_general_options
		{
			MGRAddNode *node = makeNode(MGRAddNode);
			node->if_not_exists = false;
			node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
			node->name = $3;
			node->options = $4;
			$$ = (Node*)node;
		}
	| ADD_P COORDINATOR IF_P NOT EXISTS Ident opt_general_options
		{
			MGRAddNode *node = makeNode(MGRAddNode);
			node->if_not_exists = true;
			node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
			node->name = $6;
			node->options = $7;
			$$ = (Node*)node;
		}
	| ADD_P DATANODE opt_dn_inner_type Ident opt_general_options
		{
			MGRAddNode *node = makeNode(MGRAddNode);
			node->if_not_exists = false;
			node->nodetype = $3;
			node->name = $4;
			node->options = $5;
			$$ = (Node*)node;
		}
	| ADD_P DATANODE opt_dn_inner_type IF_P NOT EXISTS Ident opt_general_options
		{
			MGRAddNode *node = makeNode(MGRAddNode);
			node->if_not_exists = true;
			node->nodetype = $3;
			node->name = $7;
			node->options = $8;
			$$ = (Node*)node;
		}
	;
	

AlterNodeStmt:
		ALTER GTM opt_gtm_inner_type Ident opt_general_options
		{
			MGRAlterNode *node = makeNode(MGRAlterNode);
			node->if_not_exists = false;
			node->nodetype = $3;
			node->name = $4;
			node->options = $5;
			$$ = (Node*)node;
		}
	| ALTER COORDINATOR Ident opt_general_options
		{
			MGRAlterNode *node = makeNode(MGRAlterNode);
			node->if_not_exists = false;
			node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
			node->name = $3;
			node->options = $4;
			$$ = (Node*)node;
		}
	| ALTER DATANODE opt_dn_inner_type Ident opt_general_options
		{
			MGRAlterNode *node = makeNode(MGRAlterNode);
			node->if_not_exists = false;
			node->nodetype = $3;
			node->name = $4;
			node->options = $5;
			$$ = (Node*)node;
		}
	;

DropNodeStmt:
	  DROP GTM opt_gtm_inner_type ObjList
		{
			MGRDropNode *node = makeNode(MGRDropNode);
			node->if_exists = false;
			node->nodetype = $3;
			node->names = $4;
			$$ = (Node*)node;
		}
	|	DROP GTM opt_gtm_inner_type IF_P EXISTS ObjList
		{
			MGRDropNode *node = makeNode(MGRDropNode);
			node->if_exists = true;
			node->nodetype = $3;
			node->names = $6;
			$$ = (Node*)node;
		}
	|	DROP COORDINATOR ObjList
		{
			MGRDropNode *node = makeNode(MGRDropNode);
			node->if_exists = false;
			node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
			node->names = $3;
			$$ = (Node*)node;
		}
	|	DROP COORDINATOR IF_P EXISTS ObjList
		{
			MGRDropNode *node = makeNode(MGRDropNode);
			node->if_exists = true;
			node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
			node->names = $5;
			$$ = (Node*)node;
		}
	|	DROP DATANODE opt_dn_inner_type ObjList
		{
			MGRDropNode *node = makeNode(MGRDropNode);
			node->if_exists = false;
			node->nodetype = $3;
			node->names = $4;
			$$ = (Node*)node;
		}
	|	DROP DATANODE opt_dn_inner_type IF_P EXISTS ObjList
		{
			MGRDropNode *node = makeNode(MGRDropNode);
			node->if_exists = true;
			node->nodetype = $3;
			node->names = $6;
			$$ = (Node*)node;
		}
	;

ListAclStmt:
		LIST ACL opt_general_all
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_list_acl_all", NULL));
			$$ = (Node*)stmt;
		}
		;

ListNodeStmt:
	  LIST NODE
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("node"), -1));
			$$ = (Node*)stmt;
		}
	| LIST NODE '(' targetList ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = $4;
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("node"), -1));
			$$ = (Node*)stmt;
		}
	| LIST NODE AConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("node"), -1));
			stmt->whereClause = make_column_in("name", $3);
			$$ = (Node*)stmt;

			check__name_isvaild($3);
		}
	| LIST NODE '(' targetList ')' AConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = $4;
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("node"), -1));
			stmt->whereClause = make_column_in("name", $6);
			$$ = (Node*)stmt;

			check__name_isvaild($6);
		}
	| LIST NODE COORDINATOR
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst("coordinator", -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("node"), -1));
			stmt->whereClause = make_column_in("type", args);
			$$ = (Node*)stmt;
		}
	|	LIST NODE DATANODE
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst("datanode master", -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("node"), -1));
			args = lappend(args,makeStringConst("datanode slave", -1));
			args = lappend(args,makeStringConst("datanode extra", -1));
			stmt->whereClause = make_column_in("type", args);
			$$ = (Node*)stmt;
		}
	|	LIST NODE DATANODE MASTER
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst("datanode master", -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("node"), -1));
			stmt->whereClause = make_column_in("type", args);
			$$ = (Node*)stmt;
		}
	|	LIST NODE DATANODE SLAVE
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst("datanode slave", -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("node"), -1));
			stmt->whereClause = make_column_in("type", args);
			$$ = (Node*)stmt;
		}
	|	LIST NODE DATANODE EXTRA
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst("datanode extra", -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("node"), -1));
			stmt->whereClause = make_column_in("type", args);
			$$ = (Node*)stmt;
		}
	;
InitNodeStmt:
/*	INIT GTM MASTER 
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_gtm_master", NULL));
*			$$ = (Node*)stmt;
*		}
*	| INIT GTM SLAVE 
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_gtm_slave", NULL));
*			$$ = (Node*)stmt;
*		}
*	| INIT GTM EXTRA 
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_gtm_extra", NULL));
*			$$ = (Node*)stmt;
*		}
*	| INIT COORDINATOR NodeConstList
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_cn_master", $3));
*			$$ = (Node*)stmt;
*		}
*	| INIT COORDINATOR  ALL
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*		 	List *args = list_make1(makeNullAConst(-1));
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_cn_master", args));
*			$$ = (Node*)stmt;
*		}
*	|	INIT DATANODE MASTER NodeConstList
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_dn_master", $4));
*			$$ = (Node*)stmt;
*		}
*	|	INIT DATANODE MASTER ALL
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*		 	List *args = list_make1(makeNullAConst(-1));
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_dn_master", args));
*			$$ = (Node*)stmt;
*		}
*	| INIT DATANODE SLAVE NodeConstList
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_dn_slave", $4));
*			$$ = (Node*)stmt;
*		}
*	| INIT DATANODE EXTRA NodeConstList
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_dn_extra", $4));
*			$$ = (Node*)stmt;
*		}
*	|	INIT DATANODE SLAVE ALL
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_dn_slave_all", NULL));
*			$$ = (Node*)stmt;
*		}
*	|	INIT DATANODE EXTRA ALL
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_init_dn_extra_all", NULL));
*			$$ = (Node*)stmt;
*		}
*	| INIT DATANODE ALL
*		{
*			SelectStmt *stmt = makeNode(SelectStmt);
*			stmt->targetList = list_make1(make_star_target(-1));
*			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("initdatanodeall"), -1));
*			$$ = (Node*)stmt;
*		}
*	| 
*/
INIT ALL
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("initall"), -1));
			with_data_checksums = false;
			$$ = (Node*)stmt;
	}
| INIT ALL DATA_CHECKSUMS
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("initall"), -1));
			with_data_checksums = true;
			$$ = (Node*)stmt;
	}
	;
StartNodeMasterStmt:
		START GTM MASTER Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_gtm_master", args));
			$$ = (Node*)stmt;
		}
	|	START GTM SLAVE Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_gtm_slave", args));
			$$ = (Node*)stmt;
		}
	| START GTM EXTRA Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_gtm_extra", args));
			$$ = (Node*)stmt;
		}
	| START GTM ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("start_gtm_all"), -1));
			$$ = (Node*)stmt;
		}
	|	START COORDINATOR NodeConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_cn_master", $3));
			$$ = (Node*)stmt;
		}
	|	START COORDINATOR ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
		 	List *args = list_make1(makeNullAConst(-1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_cn_master", args));
			$$ = (Node*)stmt;
		}
	|	START DATANODE MASTER NodeConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_dn_master", $4));
			$$ = (Node*)stmt;
		}
	| START DATANODE MASTER ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
		 	List *args = list_make1(makeNullAConst(-1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_dn_master", args));
			$$ = (Node*)stmt;
		}
	|	START DATANODE SLAVE NodeConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_dn_slave", $4));
			$$ = (Node*)stmt;
		}
	|	START DATANODE EXTRA NodeConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_dn_extra", $4));
			$$ = (Node*)stmt;
		}
	|	START DATANODE SLAVE ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
		 	List *args = list_make1(makeNullAConst(-1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_dn_slave", args));
			$$ = (Node*)stmt;
		}
	|	START DATANODE EXTRA ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
		 	List *args = list_make1(makeNullAConst(-1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_start_dn_extra", args));
			$$ = (Node*)stmt;
		}
	|	START DATANODE ALL
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("start_datanode_all"), -1));
			$$ = (Node*)stmt;
		}
	|	START ALL
		{
			mgr_check_job_in_updateparam("monitor_handle_coordinator");

			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("startall"), -1));
			$$ = (Node*)stmt;
		}
	;
StopNodeMasterStmt:
		STOP GTM MASTER Ident opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($5, -1));
			args = lappend(args,makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_gtm_master", args));
			$$ = (Node*)stmt;
		}
	|	STOP GTM SLAVE Ident opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($5, -1));
			args = lappend(args,makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_gtm_slave", args));
			$$ = (Node*)stmt;
		}
	|	STOP GTM EXTRA Ident opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($5, -1));
			args = lappend(args,makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_gtm_extra", args));
			$$ = (Node*)stmt;
		}
	| STOP GTM ALL opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			if (strcmp($4, SHUTDOWN_S) == 0)
				stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("stop_gtm_all"), -1));
			else if (strcmp($4, SHUTDOWN_F) == 0)
				stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("stop_gtm_all_f"), -1));
			else
				stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("stop_gtm_all_i"), -1));
			$$ = (Node*)stmt;
		}
	|	STOP COORDINATOR NodeConstList opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			args = list_concat(args, $3);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_cn_master", args));
			$$ = (Node*)stmt;
		}
	|	STOP COORDINATOR ALL opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			args = list_concat(args, list_make1(makeNullAConst(-1)));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_cn_master", args));
			$$ = (Node*)stmt;
		}
	|	STOP DATANODE MASTER NodeConstList opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($5, -1));
			args = list_concat(args, $4);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_dn_master", args));
			$$ = (Node*)stmt;
		}
	|	STOP DATANODE MASTER ALL opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($5, -1));
			args = list_concat(args, list_make1(makeNullAConst(-1)));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_dn_master", args));
			$$ = (Node*)stmt;
		}
	|	STOP DATANODE SLAVE NodeConstList opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($5, -1));
			args = list_concat(args, $4);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_dn_slave", args));
			$$ = (Node*)stmt;
		}
	|	STOP DATANODE SLAVE ALL opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($5, -1));
			args = list_concat(args, list_make1(makeNullAConst(-1)));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_dn_slave", args));
			$$ = (Node*)stmt;
		}
	|	STOP DATANODE EXTRA NodeConstList opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($5, -1));
			args = list_concat(args, $4);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_dn_extra", args));
			$$ = (Node*)stmt;
		}
	|	STOP DATANODE EXTRA ALL opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($5, -1));
			args = list_concat(args, list_make1(makeNullAConst(-1)));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_stop_dn_extra", args));
			$$ = (Node*)stmt;
		}

	|	STOP DATANODE ALL opt_stop_mode
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			if (strcmp($4, SHUTDOWN_S) == 0)
				stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("stop_datanode_all"), -1));
			else if (strcmp($4, SHUTDOWN_F) == 0)
				stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("stop_datanode_all_f"), -1));
			else
				stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("stop_datanode_all_i"), -1));
			$$ = (Node*)stmt;
		}
	|	STOP ALL opt_stop_mode
		{
			mgr_check_job_in_updateparam("monitor_handle_coordinator");

			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			if (strcmp($3, SHUTDOWN_S) == 0)
				stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("stopall"), -1));
			else if (strcmp($3, SHUTDOWN_F) == 0)
				stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("stopall_f"), -1));
			else
				stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("stopall_i"), -1));
			$$ = (Node*)stmt;
		}
	;
FailoverStmt:
		FAILOVER DATANODE SLAVE Ident opt_general_force
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst("slave", -1));
			args = lappend(args, makeStringConst($4, -1));
			args = lappend(args, makeBoolAConst($5, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_one_dn", args));
			$$ = (Node*)stmt;
	}
	|	FAILOVER DATANODE EXTRA Ident opt_general_force
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst("extra", -1));
			args = lappend(args, makeStringConst($4, -1));
			args = lappend(args, makeBoolAConst($5, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_one_dn", args));
			$$ = (Node*)stmt;
		}
	| FAILOVER DATANODE Ident opt_general_force
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst("either", -1));
			args = lappend(args, makeStringConst($3, -1));
			args = lappend(args, makeBoolAConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_one_dn", args));
			$$ = (Node*)stmt;
		}
	| FAILOVER GTM SLAVE Ident opt_general_force
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			args = lappend(args, makeStringConst("slave", -1));
			args = lappend(args, makeBoolAConst($5, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_gtm", args));
			$$ = (Node*)stmt;
		}
	| FAILOVER GTM EXTRA Ident opt_general_force
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($4, -1));
			args = lappend(args, makeStringConst("extra", -1));
			args = lappend(args, makeBoolAConst($5, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_gtm", args));
			$$ = (Node*)stmt;
		}
	| FAILOVER GTM Ident opt_general_force
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args, makeStringConst("either", -1));
			args = lappend(args, makeBoolAConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_gtm", args));
			$$ = (Node*)stmt;
		}
	;
opt_general_force:
	FORCE		{$$ = TRUE;}
	|/*empty*/	{$$ = FALSE;}
/* cndn end*/

DeploryStmt:
	  DEPLOY ALL opt_password
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_deploy_all", args));
			$$ = (Node*)stmt;
		}
	| DEPLOY hostname_list opt_password
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			Node *password = makeStringConst($3, -1);
			Node *hostnames = makeAArrayExpr($2, @2);
			List *args = list_make2(password, hostnames);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_deploy_hostnamelist", args));
			$$ = (Node*)stmt;
		}
	;

opt_password:
	  PASSWORD SConst		{ $$ = $2; }
	| PASSWORD ColLabel		{ $$ = $2; }
	| /* empty */			{ $$ = NULL; }
	;
opt_stop_mode:
	MODE SMART			{ $$ = pstrdup(SHUTDOWN_S); }
	| MODE S			{ $$ = pstrdup(SHUTDOWN_S); }
	| /* empty */		{ $$ = pstrdup(SHUTDOWN_S); }
	| MODE FAST	{ $$ = pstrdup(SHUTDOWN_F); }
	| MODE F	{ $$ = pstrdup(SHUTDOWN_F); }
	|	MODE IMMEDIATE		{ $$ = pstrdup(SHUTDOWN_I); }
	| MODE I			{ $$ = pstrdup(SHUTDOWN_I); }
	;

opt_gtm_inner_type:
	  MASTER { $$ = GTM_TYPE_GTM_MASTER; }
	| SLAVE { $$ = GTM_TYPE_GTM_SLAVE; }
	| EXTRA { $$ = GTM_TYPE_GTM_EXTRA; }
	;
opt_dn_inner_type:
	 MASTER { $$ = CNDN_TYPE_DATANODE_MASTER; }
	|SLAVE { $$ = CNDN_TYPE_DATANODE_SLAVE; }
	| EXTRA { $$ = CNDN_TYPE_DATANODE_EXTRA; }
	;
opt_slave_inner_type:
		GTM SLAVE { $$ = GTM_TYPE_GTM_SLAVE; }
	|	GTM EXTRA { $$ = GTM_TYPE_GTM_EXTRA; }
	|	DATANODE SLAVE { $$ = CNDN_TYPE_DATANODE_SLAVE; }
	|	DATANODE EXTRA { $$ = CNDN_TYPE_DATANODE_EXTRA; }
	;

cluster_type:
	GTM               {$$ = GTM_TYPE;}
	| COORDINATOR     {$$ = COORDINATOR_TYPE;}
	| DATANODE        {$$ = DATANODE_TYPE;}
	| DATANODE MASTER {$$ = CNDN_TYPE_DATANODE_MASTER;}
	| DATANODE SLAVE  {$$ = CNDN_TYPE_DATANODE_SLAVE;}
	| DATANODE EXTRA  {$$ = CNDN_TYPE_DATANODE_EXTRA;}
	;

sub_like_expr:
	Ident             { $$ = $1;}
	| /* empty */     { $$ = pstrdup("NULL");}
	;

ListMonitor:
	GET_CLUSTER_HEADPAGE_LINE
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("monitor_cluster_firstline_v"), -1));
			$$ = (Node*)stmt;
	}
	| GET_CLUSTER_TPS_QPS  /*monitor first page, tps,qps, the data in current 12hours*/
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("monitor_12hours_tpsqps_v"), -1));
			$$ = (Node*)stmt;
	}
	| GET_CLUSTER_CONNECT_DBSIZE_INDEXSIZE  /*monitor first page, connect,dbsize,indexsize, the data in current 12hours*/
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("monitor_12hours_connect_dbsize_indexsize_v"), -1));
			$$ = (Node*)stmt;
	}
	| GET_CLUSTER_SUMMARY  /*monitor cluster summary, the data in current time*/
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("monitor_cluster_summary_v"), -1));
			$$ = (Node*)stmt;
	}
	| GET_DATABASE_TPS_QPS /*monitor all database tps,qps, runtime at current time*/
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("monitor_all_dbname_tps_qps_runtime_v"), -1));
			$$ = (Node*)stmt;
	}
	| GET_DATABASE_TPS_QPS_INTERVAL_TIME '(' Ident ',' Ident ',' SignedIconst ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args, makeStringConst($5, -1));
			args = lappend(args, makeIntConst($7, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_databasetps_func", args));
			$$ = (Node*)stmt;
		}
	| MONITOR_DATABASETPS_FUNC_BY_TIME_PERIOD '(' Ident ',' Ident ',' Ident ')'
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args, makeStringConst($5, -1));
			args = lappend(args, makeStringConst($7, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_databasetps_func_by_time_period", args));
			$$ = (Node*)stmt;
	}
	| GET_DATABASE_SUMMARY '(' Ident')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_databasesummary_func", args));
			$$ = (Node*)stmt;
		}
	| GET_SLOWLOG '(' Ident ',' Ident ',' Ident ',' SignedIconst ',' SignedIconst ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args, makeStringConst($5, -1));
			args = lappend(args, makeStringConst($7, -1));
			args = lappend(args, makeIntConst($9, -1));
			args = lappend(args, makeIntConst($11, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_slowlog_func_page", args));
			$$ = (Node*)stmt;
		}
	| GET_SLOWLOG_COUNT '(' Ident ',' Ident ',' Ident ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args, makeStringConst($5, -1));
			args = lappend(args, makeStringConst($7, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_slowlog_count_func", args));
			$$ = (Node*)stmt;
		}
	| CHECK_USER '(' Ident ',' Ident ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeStringConst($3, -1));
			args = lappend(args, makeStringConst($5, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_checkuser_func", args));
			$$ = (Node*)stmt;
		}
	| GET_USER_INFO  SignedIconst
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($2, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_getuserinfo_func", args));
			$$ = (Node*)stmt;
		}
	| UPDATE_USER SignedIconst '(' Ident ',' Ident ',' Ident ',' Ident ',' Ident ',' Ident ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($2, -1));
			args = lappend(args, makeStringConst($4, -1));
			args = lappend(args, makeStringConst($6, -1));
			args = lappend(args, makeStringConst($8, -1));
			args = lappend(args, makeStringConst($10, -1));
			args = lappend(args, makeStringConst($12, -1));
			args = lappend(args, makeStringConst($14, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_updateuserinfo_func", args));
			$$ = (Node*)stmt;
		}
	| CHECK_PASSWORD '(' SignedIconst ',' Ident ')'
	{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, -1));
			args = lappend(args, makeStringConst($5, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_checkuserpassword_func", args));
			$$ = (Node*)stmt;
	}
	| UPDATE_PASSWORD SignedIconst '(' Ident ')'
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($2, -1));
			args = lappend(args, makeStringConst($4, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("monitor_updateuserpassword_func", args));
			$$ = (Node*)stmt;
		}
	;

ShowStmt:
	SHOW Ident var_showparam
	{
		SelectStmt *stmt = makeNode(SelectStmt);
		List *args = list_make1(makeStringConst($2, @2));
		args = lappend(args, makeStringConst($3, @3));
		stmt->targetList = list_make1(make_star_target(-1));
		stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_show_var_param", args));
		$$ = (Node*)stmt;
	}
	;

FlushHost:
FLUSH HOST
	{
		MGRFlushHost *node = makeNode(MGRFlushHost);
		$$ = (Node*)node;
	}
	;
AddJobitemStmt:
	ADD_P ITEM Ident opt_general_options
	{
			MonitorJobitemAdd *node = makeNode(MonitorJobitemAdd);
			node->if_not_exists = false;
			node->name = $3;
			node->options = $4;
			$$ = (Node*)node;
	}
	| ADD_P ITEM IF_P NOT EXISTS Ident opt_general_options
	{
			MonitorJobitemAdd *node = makeNode(MonitorJobitemAdd);
			node->if_not_exists = true;
			node->name = $6;
			node->options = $7;
			$$ = (Node*)node;
	}
	| ADD_P JOB Ident opt_general_options
	{
			MonitorJobAdd *node = makeNode(MonitorJobAdd);
			node->if_not_exists = false;
			node->name = $3;
			node->options = $4;
			$$ = (Node*)node;
	}
	| ADD_P JOB IF_P NOT EXISTS Ident opt_general_options
	{
			MonitorJobAdd *node = makeNode(MonitorJobAdd);
			node->if_not_exists = true;
			node->name = $6;
			node->options = $7;
			$$ = (Node*)node;
	}
	;

AlterJobitemStmt:
	ALTER ITEM Ident opt_general_options
	{
		MonitorJobitemAlter *node = makeNode(MonitorJobitemAlter);
		node->name = $3;
		node->options = $4;
		$$ = (Node*)node;
	}
	| ALTER JOB Ident opt_general_options
	{
		MonitorJobAlter *node = makeNode(MonitorJobAlter);
		node->name = $3;
		node->options = $4;
		$$ = (Node*)node;
	}
	;

DropJobitemStmt:
	DROP ITEM ObjList
	{
		MonitorJobitemDrop *node = makeNode(MonitorJobitemDrop);
		node->if_exists = false;
		node->namelist = $3;
		$$ = (Node*)node;
	}
	|	DROP ITEM IF_P EXISTS ObjList
	{
		MonitorJobitemDrop *node = makeNode(MonitorJobitemDrop);
		node->if_exists = true;
		node->namelist = $5;
		$$ = (Node*)node;
	}
	| DROP JOB ObjList
	{
		MonitorJobDrop *node = makeNode(MonitorJobDrop);
		node->if_exists = false;
		node->namelist = $3;
		$$ = (Node*)node;
	}
	| DROP JOB IF_P EXISTS ObjList
	{
		MonitorJobDrop *node = makeNode(MonitorJobDrop);
		node->if_exists = true;
		node->namelist = $5;
		$$ = (Node*)node;
	}
	;

ListJobStmt:
	  LIST JOB
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("job"), -1));
			$$ = (Node*)stmt;
		}
	|	LIST JOB AConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("job"), -1));
			stmt->whereClause = make_column_in("name", $3);
			$$ = (Node*)stmt;

			check_job_name_isvaild($3);
		}
	| LIST ITEM
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("jobitem"), -1));
			$$ = (Node*)stmt;
		}
	|	LIST ITEM AConstList
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeRangeVar(pstrdup("adbmgr"), pstrdup("jobitem"), -1));
			stmt->whereClause = make_column_in("item", $3);
			$$ = (Node*)stmt;

			check_jobitem_name_isvaild($3);
		}
		;

AddExtensionStmt:
		ADD_P EXTENSION Ident
		{
			MgrExtensionAdd *node = makeNode(MgrExtensionAdd);
			node->cmdtype = EXTENSION_CREATE;
			node->name = $3;
			$$ = (Node*)node;
		}
		;
DropExtensionStmt:
		DROP EXTENSION Ident
		{
			MgrExtensionDrop *node = makeNode(MgrExtensionDrop);
			node->cmdtype = EXTENSION_DROP;
			node->name = $3;
			$$ = (Node*)node;
		}
		;
RemoveNodeStmt:
		REMOVE GTM opt_gtm_inner_type ObjList
		{
			MgrRemoveNode *node = makeNode(MgrRemoveNode);
			node->nodetype = $3;
			node->names = $4;
			$$ = (Node*)node;
		}
	|	REMOVE DATANODE opt_dn_inner_type ObjList
		{
			MgrRemoveNode *node = makeNode(MgrRemoveNode);
			node->nodetype = $3;
			node->names = $4;
			$$ = (Node*)node;
		}
	|	REMOVE COORDINATOR ObjList
		{
			MgrRemoveNode *node = makeNode(MgrRemoveNode);
			node->nodetype = CNDN_TYPE_COORDINATOR_MASTER;
			node->names = $3;
			$$ = (Node*)node;
		}	
	;

FailoverManualStmt:
		ADBMGR PROMOTE opt_slave_inner_type Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, @3));
			args = lappend(args, makeStringConst($4, @4));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_manual_adbmgr_func", args));
			$$ = (Node*)stmt;
		}
	|	PROMOTE GTM opt_gtm_inner_type Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, @3));
			args = lappend(args, makeStringConst($4, @4));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_manual_promote_func", args));
			$$ = (Node*)stmt;
		}
	| PROMOTE DATANODE opt_dn_inner_type Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, @3));
			args = lappend(args, makeStringConst($4, @4));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_manual_promote_func", args));
			$$ = (Node*)stmt;
		}
	|	CONFIG DATANODE MASTER Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst(CNDN_TYPE_DATANODE_MASTER, @3));
			args = lappend(args, makeStringConst($4, @4));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_manual_pgxcnode_func", args));
			$$ = (Node*)stmt;
		}
	| REWIND opt_slave_inner_type Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($2, @2));
			args = lappend(args, makeStringConst($3, @3));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_failover_manual_rewind_func", args));
			$$ = (Node*)stmt;
		}
	;

SwitchoverStmt:
	SWITCHOVER GTM opt_gtm_inner_type Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, @3));
			args = lappend(args, makeStringConst($4, @4));
			args = lappend(args, makeIntConst(0, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_switchover_func", args));
			$$ = (Node*)stmt;
		}
	| SWITCHOVER GTM opt_gtm_inner_type Ident FORCE
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, @3));
			args = lappend(args, makeStringConst($4, @4));
			args = lappend(args, makeIntConst(1, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_switchover_func", args));
			$$ = (Node*)stmt;
		}
	| SWITCHOVER DATANODE opt_dn_inner_type Ident
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, @3));
			args = lappend(args, makeStringConst($4, @4));
			args = lappend(args, makeIntConst(0, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_switchover_func", args));
			$$ = (Node*)stmt;
		}
	| SWITCHOVER DATANODE opt_dn_inner_type Ident FORCE
		{
			SelectStmt *stmt = makeNode(SelectStmt);
			List *args = list_make1(makeIntConst($3, @3));
			args = lappend(args, makeStringConst($4, @4));
			args = lappend(args, makeIntConst(1, -1));
			stmt->targetList = list_make1(make_star_target(-1));
			stmt->fromClause = list_make1(makeNode_RangeFunction("mgr_switchover_func", args));
			$$ = (Node*)stmt;
		}
		;

unreserved_keyword:
	  ACL
	| ACTIVATE
	| ADBMGR
	| ADD_P
	| AGENT
	| ALTER
	| APPEND
	| CHECK_PASSWORD
	| CHECK_USER
	| CLEAN
	| CONFIG
	| CLUSTER
	| DATA_CHECKSUMS
	| DEPLOY
	| DROP
	| EXISTS
	| EXTRA
	| EXTENSION
	| F
	| FAILOVER
	| FAST
	| FLUSH
	| FROM
	| GET_AGTM_NODE_TOPOLOGY
	| GET_ALARM_INFO_ASC
	| GET_ALARM_INFO_COUNT
	| GET_ALARM_INFO_DESC
	| GET_ALL_NODENAME_IN_SPEC_HOST
	| GET_CLUSTER_TPS_QPS
	| GET_CLUSTER_CONNECT_DBSIZE_INDEXSIZE
	| GET_CLUSTER_HEADPAGE_LINE
	| GET_CLUSTER_SUMMARY
	| GET_COORDINATOR_NODE_TOPOLOGY
	| GET_DATABASE_SUMMARY
	| GET_DATABASE_TPS_QPS
	| GET_DATABASE_TPS_QPS_INTERVAL_TIME
	| GET_DATANODE_NODE_TOPOLOGY
	| GET_DB_THRESHOLD_ALL_TYPE
	| GET_HOST_HISTORY_USAGE
	| GET_HOST_HISTORY_USAGE_BY_TIME_PERIOD
	| GET_HOST_LIST_ALL
	| GET_HOST_LIST_SPEC
	| GET_SLOWLOG
	| GET_SLOWLOG_COUNT
	| GET_THRESHOLD_ALL_TYPE
	| GET_THRESHOLD_TYPE
	| GET_USER_INFO
	| GTM
	| HBA
	| HOST
	| JOB
	| I
	| IF_P
	| IMMEDIATE
	| INIT
	| ITEM
	| LIST
	| MASTER
	| MODE
	| MONITOR
	| NODE
	| OFF
	| PARAM
	| PASSWORD
	| PROMOTE
	| REMOVE
	| RESET
	| REVOKE
	| RESOLVE_ALARM
	| REWIND
	| S
	| SET
	| SHOW
	| SLAVE
	| SMART
	| START
	| STOP
	| SWITCHOVER
	| TO
	| UPDATE_PASSWORD
	| UPDATE_THRESHOLD_VALUE
	| UPDATE_USER
	| USER
	;

reserved_keyword:
	  ALL
	| FALSE_P
	| FORCE
	| NOT
	| TRUE_P
	| ON
	| CREATE
	| GRANT
	| COORDINATOR
	| DATANODE
	| STATUS
	;

%%
/*
 * The signature of this function is required by bison.  However, we
 * ignore the passed yylloc and instead use the last token position
 * available from the scanner.
 */
static void
mgr_yyerror(YYLTYPE *yylloc, core_yyscan_t yyscanner, const char *msg)
{
	parser_yyerror(msg);
}

static int mgr_yylex(union YYSTYPE *lvalp, YYLTYPE *llocp,
		   core_yyscan_t yyscanner)
{
	return core_yylex(&(lvalp->core_yystype), llocp, yyscanner);
}

List *mgr_parse_query(const char *query_string)
{
	core_yyscan_t yyscanner;
	mgr_yy_extra_type yyextra;
	int			yyresult;

	/* initialize the flex scanner */
	yyscanner = scanner_init(query_string, &yyextra.core_yy_extra,
							 ManagerKeywords, NumManagerKeywords);

	yyextra.parsetree = NIL;

	/* Parse! */
	yyresult = mgr_yyparse(yyscanner);

	/* Clean up (release memory) */
	scanner_finish(yyscanner);

	if (yyresult)				/* error */
		return NIL;

	return yyextra.parsetree;
}

static Node* make_column_in(const char *col_name, List *values)
{
	A_Expr *expr;
	ColumnRef *col = makeNode(ColumnRef);
	col->fields = list_make1(makeString(pstrdup(col_name)));
	col->location = -1;
	expr = makeA_Expr(AEXPR_IN
			, list_make1(makeString(pstrdup("=")))
			, (Node*)col
			, (Node*)values
			, -1);
	return (Node*)expr;
}

static Node* makeNode_RangeFunction(const char *func_name, List *func_args)
{
	RangeFunction *n = makeNode(RangeFunction);
	n->lateral = false;
	n->funccallnode = make_func_call(func_name, func_args);
	n->alias = NULL;
	n->coldeflist = NIL;
	return (Node *) n;
}

static Node* make_func_call(const char *func_name, List *func_args)
{
	FuncCall *n = makeNode(FuncCall);
	n->funcname = list_make1(makeString(pstrdup(func_name)));
	n->args = func_args;
	n->agg_order = NIL;
	n->agg_star = FALSE;
	n->agg_distinct = FALSE;
	n->func_variadic = FALSE;
	n->over = NULL;
	n->location = -1;
	return (Node *)n;
}
#if 0
static List* make_start_agent_args(List *options)
{
	List *result;
	char *password = NULL;
	ListCell *lc;
	DefElem *def;
	
	/* for(lc=list_head(options);lc;lc=lnext(lc)) */
	foreach(lc,options)
	{
		def = lfirst(lc);
		Assert(def && IsA(def, DefElem));
		if(strcmp(def->defname, "password") == 0)
			password = defGetString(def);
		else
		{
			ereport(ERROR, (errcode(ERRCODE_SYNTAX_ERROR)
				,errmsg("option \"%s\" not recognized", def->defname)
				,errhint("option is password.")));
		}
	}
	
	if(password == NULL)
		result = list_make1(makeNullAConst(-1));
	else
		result = list_make1(makeStringConst(password, -1));

	return result;
}
#endif

static Node* make_ColumnRef(const char *col_name)
{
	ColumnRef *col = makeNode(ColumnRef);
	col->fields = list_make1(makeString(pstrdup(col_name)));
	col->location = -1;
	return (Node*)col;
}

static Node* make_whereClause_for_datanode(char* node_type_str, List* node_name_list, char* like_expr)
{
	Node* whereClause = NULL;

	whereClause =
		(Node *) makeA_Expr(AEXPR_AND, NIL,
			(Node *) makeA_Expr(AEXPR_OR, NIL,
				(Node *) makeA_Expr(AEXPR_AND, NIL,
					(Node *) makeSimpleA_Expr(AEXPR_OP, "~", make_ColumnRef("nodetype"), makeStringConst(pstrdup("^datanode master"), -1), -1),
					(Node *) makeSimpleA_Expr(AEXPR_OP, "=", make_ColumnRef("nodename"), makeStringConst(pstrdup("*"), -1), -1),
									-1),
				(Node *) makeA_Expr(AEXPR_AND, NIL,
					(Node *) makeSimpleA_Expr(AEXPR_IN, "=", make_ColumnRef("nodename"), (Node*)node_name_list, -1),
					(Node *) makeSimpleA_Expr(AEXPR_OP, "=", make_ColumnRef("nodetype"), makeStringConst(pstrdup(node_type_str), -1), -1),
									-1),
									-1),
			(Node *)makeSimpleA_Expr(AEXPR_OP, "~~",
								make_ColumnRef("key"),
								makeStringConst(pstrdup(like_expr), -1), -1),
								-1);
	return  (Node *)whereClause;
}

static Node* make_whereClause_for_coord(char* node_type_str, List* node_name_list, char* like_expr)
{
	Node* whereClause = NULL;

	whereClause =
		(Node *) makeA_Expr(AEXPR_AND, NIL,
			(Node *) makeA_Expr(AEXPR_OR, NIL,
				(Node *) makeA_Expr(AEXPR_AND, NIL,
					(Node *) makeSimpleA_Expr(AEXPR_OP, "~", make_ColumnRef("nodetype"), makeStringConst(pstrdup("^coordinator"), -1), -1),
					(Node *) makeSimpleA_Expr(AEXPR_OP, "=", make_ColumnRef("nodename"), makeStringConst(pstrdup("*"), -1), -1),
									-1),
				(Node *) makeA_Expr(AEXPR_AND, NIL,
					(Node *) makeSimpleA_Expr(AEXPR_IN, "=", make_ColumnRef("nodename"), (Node*)node_name_list, -1),
					(Node *) makeSimpleA_Expr(AEXPR_OP, "=", make_ColumnRef("nodetype"), makeStringConst(pstrdup(node_type_str), -1), -1),
									-1),
									-1),
			(Node *)makeSimpleA_Expr(AEXPR_OP, "~~",
								make_ColumnRef("key"),
								makeStringConst(pstrdup(like_expr), -1), -1),
								-1);
	return  (Node *)whereClause;
}

static Node* make_whereClause_for_gtm(char* node_type_str, List* node_name_list, char* like_expr)
{
	Node * whereClause = NULL;

	whereClause =
		(Node *) makeA_Expr(AEXPR_AND, NIL,
			(Node *) makeA_Expr(AEXPR_OR, NIL,
				(Node *) makeA_Expr(AEXPR_AND, NIL,
					(Node *) makeSimpleA_Expr(AEXPR_OP, "~", make_ColumnRef("nodetype"), makeStringConst(pstrdup("^gtm"), -1), -1),
					(Node *) makeSimpleA_Expr(AEXPR_OP, "=", make_ColumnRef("nodename"), makeStringConst(pstrdup("*"), -1), -1),
									-1),
				(Node *) makeA_Expr(AEXPR_AND, NIL,
					(Node *) makeSimpleA_Expr(AEXPR_IN, "=", make_ColumnRef("nodename"), (Node*)node_name_list, -1),
					(Node *) makeSimpleA_Expr(AEXPR_OP, "=", make_ColumnRef("nodetype"), makeStringConst(pstrdup(node_type_str), -1), -1),
									-1),
									-1),
			(Node *)makeSimpleA_Expr(AEXPR_OP, "~~",
								make_ColumnRef("key"),
								makeStringConst(pstrdup(like_expr), -1), -1),
								-1);
	return  (Node *)whereClause;
}

static void check_node_name_isvaild(char node_type, List* node_name_list)
{
	ListCell *lc = NULL;
	A_Const *node_name  = NULL;
	NameData name;
	Relation rel_node;
	HeapScanDesc scan;
	ScanKeyData key[2];
	HeapTuple tuple;

	foreach(lc, node_name_list)
	{
		node_name = (A_Const *) lfirst(lc);
		Assert(node_name && IsA(&(node_name->val), String));

		namestrcpy(&name, strVal(&(node_name->val)));
		ScanKeyInit(&key[0]
			,Anum_mgr_node_nodename
			,BTEqualStrategyNumber, F_NAMEEQ
			,NameGetDatum(&name));

		ScanKeyInit(&key[1]
			,Anum_mgr_node_nodetype
			,BTEqualStrategyNumber
			,F_CHAREQ
			,CharGetDatum(node_type));

		rel_node = heap_open(NodeRelationId, AccessShareLock);
		scan = heap_beginscan(rel_node, SnapshotNow, 2, key);

		if ((tuple = heap_getnext(scan, ForwardScanDirection)) == NULL)
		{
			heap_endscan(scan);
			heap_close(rel_node, AccessShareLock);

			switch (node_type)
			{
				case CNDN_TYPE_COORDINATOR_MASTER:
					ereport(ERROR, (errmsg("coordinator \"%s\" does not exist", NameStr(name))));
					break;
				case CNDN_TYPE_DATANODE_MASTER:
					ereport(ERROR, (errmsg("datanode master \"%s\" does not exist", NameStr(name))));
					break;
				case CNDN_TYPE_DATANODE_SLAVE:
					ereport(ERROR, (errmsg("datanode slave \"%s\" does not exist", NameStr(name))));
					break;
				case CNDN_TYPE_DATANODE_EXTRA:
					ereport(ERROR, (errmsg("datanode extra \"%s\" does not exist", NameStr(name))));
					break;
				case GTM_TYPE_GTM_SLAVE:
					ereport(ERROR, (errmsg("gtm slave \"%s\" does not exist", NameStr(name))));
					break;
				case GTM_TYPE_GTM_EXTRA:
					ereport(ERROR, (errmsg("gtm extra \"%s\" does not exist", NameStr(name))));
					break;
				default:
					ereport(ERROR, (errmsg("node type \"%c\" does not exist", node_type)));
					break;
			}
		}

		heap_endscan(scan);
		heap_close(rel_node, AccessShareLock);
	}

	return;
}

static void check_host_name_isvaild(List *node_name_list)
{
	ListCell *lc = NULL;
	A_Const *host_name  = NULL;
	NameData name;
	Relation rel_node;
	HeapScanDesc scan;
	ScanKeyData key[1];
	HeapTuple tuple;

	foreach(lc, node_name_list)
	{
		host_name = (A_Const *) lfirst(lc);
		Assert(host_name && IsA(&(host_name->val), String));
		namestrcpy(&name, strVal(&(host_name->val)));

		ScanKeyInit(&key[0]
			,Anum_mgr_node_nodename
			,BTEqualStrategyNumber, F_NAMEEQ
			,NameGetDatum(&name));

		rel_node = heap_open(HostRelationId, AccessShareLock);
		scan = heap_beginscan(rel_node, SnapshotNow, 1, key);

		if ((tuple = heap_getnext(scan, ForwardScanDirection)) == NULL)
		{
			heap_endscan(scan);
			heap_close(rel_node, AccessShareLock);

			ereport(ERROR, (errmsg("host name \"%s\" does not exist", NameStr(name))));
		}

		heap_endscan(scan);
		heap_close(rel_node, AccessShareLock);
	}

	return;
}

static void check__name_isvaild(List *node_name_list)
{
	ListCell *lc = NULL;
	A_Const *host_name  = NULL;
	NameData name;
	Relation rel_node;
	HeapScanDesc scan;
	ScanKeyData key[1];
	HeapTuple tuple;

	foreach(lc, node_name_list)
	{
		host_name = (A_Const *) lfirst(lc);
		Assert(host_name && IsA(&(host_name->val), String));
		namestrcpy(&name, strVal(&(host_name->val)));

		ScanKeyInit(&key[0]
			,Anum_mgr_node_nodename
			,BTEqualStrategyNumber, F_NAMEEQ
			,NameGetDatum(&name));

		rel_node = heap_open(NodeRelationId, AccessShareLock);
		scan = heap_beginscan(rel_node, SnapshotNow, 1, key);

		if ((tuple = heap_getnext(scan, ForwardScanDirection)) == NULL)
		{
			heap_endscan(scan);
			heap_close(rel_node, AccessShareLock);

			ereport(ERROR, (errmsg("node name \"%s\" does not exist", NameStr(name))));
		}

		heap_endscan(scan);
		heap_close(rel_node, AccessShareLock);
	}

	return;
}

static void check_job_name_isvaild(List *node_name_list)
{
	ListCell *lc = NULL;
	A_Const *job_name  = NULL;
	NameData name;
	Relation rel_job;
	HeapScanDesc scan;
	ScanKeyData key[1];
	HeapTuple tuple;

	foreach(lc, node_name_list)
	{
		job_name = (A_Const *) lfirst(lc);
		Assert(job_name && IsA(&(job_name->val), String));
		namestrcpy(&name, strVal(&(job_name->val)));

		ScanKeyInit(&key[0]
			,Anum_monitor_job_name
			,BTEqualStrategyNumber, F_NAMEEQ
			,NameGetDatum(&name));

		rel_job = heap_open(MjobRelationId, AccessShareLock);
		scan = heap_beginscan(rel_job, SnapshotNow, 1, key);

		if ((tuple = heap_getnext(scan, ForwardScanDirection)) == NULL)
		{
			heap_endscan(scan);
			heap_close(rel_job, AccessShareLock);

			ereport(ERROR, (errmsg("job name \"%s\" does not exist", NameStr(name))));
		}

		heap_endscan(scan);
		heap_close(rel_job, AccessShareLock);
	}

	return;
}

static void check_jobitem_name_isvaild(List *node_name_list)
{
	ListCell *lc = NULL;
	A_Const *jobitem_name  = NULL;
	NameData name;
	Relation rel_jobitem;
	HeapScanDesc scan;
	ScanKeyData key[1];
	HeapTuple tuple;

	foreach(lc, node_name_list)
	{
		jobitem_name = (A_Const *) lfirst(lc);
		Assert(jobitem_name && IsA(&(jobitem_name->val), String));
		namestrcpy(&name, strVal(&(jobitem_name->val)));

		ScanKeyInit(&key[0]
			,Anum_monitor_jobitem_itemname
			,BTEqualStrategyNumber, F_NAMEEQ
			,NameGetDatum(&name));

		rel_jobitem = heap_open(MjobitemRelationId, AccessShareLock);
		scan = heap_beginscan(rel_jobitem, SnapshotNow, 1, key);

		if ((tuple = heap_getnext(scan, ForwardScanDirection)) == NULL)
		{
			heap_endscan(scan);
			heap_close(rel_jobitem, AccessShareLock);

			ereport(ERROR, (errmsg("job item name \"%s\" does not exist", NameStr(name))));
		}

		heap_endscan(scan);
		heap_close(rel_jobitem, AccessShareLock);
	}

	return;
}


