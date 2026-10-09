#!/usr/bin/env python3
# Step 1a: add INSTALL_FILTER_RULE(0x23) + FILTER_INSTALLED_NOTIF(0x24)
# server handlers to the mainline IPA driver, returning empty SUCCESS
# responses (no actual filter-table write).  This is the cheapest probe of
# the "modem only wants an ack" hypothesis behind the
# ipa_ipfltr.init_done == TRUE assertion.
#
# Files patched:
#   drivers/net/ipa/ipa_qmi_msg.h  (msg ids, structs, ei decls)
#   drivers/net/ipa/ipa_qmi_msg.c  (ei definitions)
#   drivers/net/ipa/ipa_qmi.c      (handlers + registration)
import shutil, re

SRC = "/root/z17s-kbuild/linux-6.12.95/drivers/net/ipa"

def load(fn):
    p = SRC + "/" + fn
    return p, open(p).read()

def backup(p):
    if not __import__("os").path.exists(p + ".orig-step1a"):
        shutil.copy2(p, p + ".orig-step1a")

def sub1(t, old, new, tag):
    n = t.count(old)
    if n != 1:
        print("  !! %-44s matched %d (expected 1)" % (tag, n))
        return t, False
    print("  ok %-44s" % tag)
    return t.replace(old, new, 1), True

ok = True

# ============================================================ ipa_qmi_msg.h
p, t = load("ipa_qmi_msg.h")
backup(p)

t, r = sub1(t,
"""#define IPA_QMI_INDICATION_REGISTER	0x20	/* modem -> AP request */
#define IPA_QMI_INIT_DRIVER		0x21	/* AP -> modem request */
#define IPA_QMI_INIT_COMPLETE		0x22	/* AP -> modem indication */
#define IPA_QMI_DRIVER_INIT_COMPLETE	0x35	/* modem -> AP request */
""",
"""#define IPA_QMI_INDICATION_REGISTER	0x20	/* modem -> AP request */
#define IPA_QMI_INIT_DRIVER		0x21	/* AP -> modem request */
#define IPA_QMI_INIT_COMPLETE		0x22	/* AP -> modem indication */
#define IPA_QMI_INSTALL_FILTER_RULE	0x23	/* modem -> AP request (Z17S) */
#define IPA_QMI_FILTER_INSTALLED_NOTIF	0x24	/* modem -> AP request (Z17S) */
#define IPA_QMI_DRIVER_INIT_COMPLETE	0x35	/* modem -> AP request */
""", "msg.h: ids")
ok &= r

t, r = sub1(t,
"""#define IPA_QMI_INDICATION_REGISTER_REQ_SZ	20	/* -> server handle */
""",
"""#define IPA_QMI_INDICATION_REGISTER_REQ_SZ	20	/* -> server handle */
#define IPA_QMI_INSTALL_FILTER_RULE_REQ_SZ	8	/* -> server handle (Z17S) */
#define IPA_QMI_INSTALL_FILTER_RULE_RSP_SZ	7	/* <- server handle (Z17S) */
#define IPA_QMI_FILTER_INSTALLED_NOTIF_REQ_SZ	12	/* -> server handle (Z17S) */
#define IPA_QMI_FILTER_INSTALLED_NOTIF_RSP_SZ	7	/* <- server handle (Z17S) */
""", "msg.h: sizes")
ok &= r

t, r = sub1(t,
"""#define IPA_QMI_SERVER_MAX_RCV_SZ		8
""",
"""#define IPA_QMI_SERVER_MAX_RCV_SZ		12
""", "msg.h: server rcv sz")
ok &= r

# add structs + ei decls before the extern block
t, r = sub1(t,
"""/* Message structure definitions defined in "ipa_qmi_msg.c" */
""",
"""/*
 * Z17S (msm8998) modem-init compatibility.
 *
 * The msm8998 modem firmware, after completing DRIVER_INIT_COMPLETE, sends
 * INSTALL_FILTER_RULE and FILTER_INSTALLED_NOTIF requests.  The mainline
 * driver has no handlers for these, so the modem never sees an ack and its
 * IPA IP-filter init (ipa_ipfltr.init_done) never completes, tripping the
 * "ipa_sio.c:2107 IPA Assert: ipa_ipfltr.init_done == TRUE failed" crash.
 *
 * Step 1a probes the cheapest hypothesis: the modem only needs an ack.
 * We register the two message IDs and reply SUCCESS with an empty body,
 * without writing anything to the IPA filter tables.
 */
struct ipa_install_filter_rule_req {
	u8	filter_spec_list_valid;
	u32	filter_spec_list_len;
};

struct ipa_install_filter_rule_rsp {
	struct qmi_response_type_v01	rsp;
};

struct ipa_filter_installed_notif_req {
	u32	source_pipe_index;
	u32	install_status;
};

struct ipa_filter_installed_notif_rsp {
	struct qmi_response_type_v01	rsp;
};

/* Message structure definitions defined in "ipa_qmi_msg.c" */
""", "msg.h: structs")
ok &= r

t, r = sub1(t,
"""extern const struct qmi_elem_info ipa_init_modem_driver_req_ei[];
extern const struct qmi_elem_info ipa_init_modem_driver_rsp_ei[];
""",
"""extern const struct qmi_elem_info ipa_init_modem_driver_req_ei[];
extern const struct qmi_elem_info ipa_init_modem_driver_rsp_ei[];
extern const struct qmi_elem_info ipa_install_filter_rule_req_ei[];
extern const struct qmi_elem_info ipa_install_filter_rule_rsp_ei[];
extern const struct qmi_elem_info ipa_filter_installed_notif_req_ei[];
extern const struct qmi_elem_info ipa_filter_installed_notif_rsp_ei[];
""", "msg.h: ei decls")
ok &= r

open(p, "w").write(t)

# ============================================================ ipa_qmi_msg.c
p, t = load("ipa_qmi_msg.c")
backup(p)

t, r = sub1(t,
"""#include "ipa_qmi_msg.h"
""",
"""#include "ipa_qmi_msg.h"

/* Z17S Step 1a: minimal decode of INSTALL_FILTER_RULE request (we ignore the
 * filter spec list; we only need the request to be accepted so we can ack).
 */
const struct qmi_elem_info ipa_install_filter_rule_req_ei[] = {
	{
		.data_type	= QMI_OPT_FLAG,
		.elem_len	= 1,
		.elem_size	=
			sizeof_field(struct ipa_install_filter_rule_req,
				     filter_spec_list_valid),
		.tlv_type	= 0x10,
		.offset		= offsetof(struct ipa_install_filter_rule_req,
					   filter_spec_list_valid),
	},
	{
		.data_type	= QMI_UNSIGNED_4_BYTE,
		.elem_len	= 1,
		.elem_size	=
			sizeof_field(struct ipa_install_filter_rule_req,
				     filter_spec_list_len),
		.tlv_type	= 0x11,
		.offset		= offsetof(struct ipa_install_filter_rule_req,
					   filter_spec_list_len),
	},
	{
		.data_type	= QMI_EOTI,
	},
};

const struct qmi_elem_info ipa_install_filter_rule_rsp_ei[] = {
	{
		.data_type	= QMI_STRUCT,
		.elem_len	= 1,
		.elem_size	=
			sizeof_field(struct ipa_install_filter_rule_rsp,
				     rsp),
		.tlv_type	= 0x02,
		.offset		= offsetof(struct ipa_install_filter_rule_rsp,
					   rsp),
		.ei_array	= qmi_response_type_v01_ei,
	},
	{
		.data_type	= QMI_EOTI,
	},
};

const struct qmi_elem_info ipa_filter_installed_notif_req_ei[] = {
	{
		.data_type	= QMI_UNSIGNED_4_BYTE,
		.elem_len	= 1,
		.elem_size	=
			sizeof_field(struct ipa_filter_installed_notif_req,
				     source_pipe_index),
		.tlv_type	= 0x01,
		.offset		= offsetof(struct ipa_filter_installed_notif_req,
					   source_pipe_index),
	},
	{
		.data_type	= QMI_UNSIGNED_4_BYTE,
		.elem_len	= 1,
		.elem_size	=
			sizeof_field(struct ipa_filter_installed_notif_req,
				     install_status),
		.tlv_type	= 0x02,
		.offset		= offsetof(struct ipa_filter_installed_notif_req,
					   install_status),
	},
	{
		.data_type	= QMI_EOTI,
	},
};

const struct qmi_elem_info ipa_filter_installed_notif_rsp_ei[] = {
	{
		.data_type	= QMI_STRUCT,
		.elem_len	= 1,
		.elem_size	=
			sizeof_field(struct ipa_filter_installed_notif_rsp,
				     rsp),
		.tlv_type	= 0x02,
		.offset		= offsetof(struct ipa_filter_installed_notif_rsp,
					   rsp),
		.ei_array	= qmi_response_type_v01_ei,
	},
	{
		.data_type	= QMI_EOTI,
	},
};
""", "msg.c: ei defs")
ok &= r

open(p, "w").write(t)

# ============================================================ ipa_qmi.c
p, t = load("ipa_qmi.c")
backup(p)

# insert the two handlers before the server_msg_handlers table
t, r = sub1(t,
"""/* The server handles two request message types sent by the modem. */
static const struct qmi_msg_handler ipa_server_msg_handlers[] = {
""",
"""/* Z17S Step 1a: respond to the modem's INSTALL_FILTER_RULE request with a
 * bare SUCCESS ack, without writing filter rules (probe whether the modem
 * only needs the ack to complete its ipa_ipfltr.init_done).
 */
static void ipa_server_install_filter_rule(struct qmi_handle *qmi,
					   struct sockaddr_qrtr *sq,
					   struct qmi_txn *txn,
					   const void *decoded)
{
	struct ipa_install_filter_rule_rsp rsp = { };
	struct ipa_qmi *ipa_qmi;
	struct ipa *ipa;
	int ret;

	ipa_qmi = container_of(qmi, struct ipa_qmi, server_handle);
	ipa = container_of(ipa_qmi, struct ipa, qmi);

	rsp.rsp.result = QMI_RESULT_SUCCESS_V01;
	rsp.rsp.error = QMI_ERR_NONE_V01;

	ret = qmi_send_response(qmi, sq, txn, IPA_QMI_INSTALL_FILTER_RULE,
				IPA_QMI_INSTALL_FILTER_RULE_RSP_SZ,
				ipa_install_filter_rule_rsp_ei, &rsp);
	if (ret)
		dev_err(ipa->dev,
			"error %d sending install filter rule response\\n", ret);
}

/* Z17S Step 1a: respond to the modem's FILTER_INSTALLED_NOTIF request. */
static void ipa_server_filter_installed_notif(struct qmi_handle *qmi,
					      struct sockaddr_qrtr *sq,
					      struct qmi_txn *txn,
					      const void *decoded)
{
	struct ipa_filter_installed_notif_rsp rsp = { };
	struct ipa_qmi *ipa_qmi;
	struct ipa *ipa;
	int ret;

	ipa_qmi = container_of(qmi, struct ipa_qmi, server_handle);
	ipa = container_of(ipa_qmi, struct ipa, qmi);

	rsp.rsp.result = QMI_RESULT_SUCCESS_V01;
	rsp.rsp.error = QMI_ERR_NONE_V01;

	ret = qmi_send_response(qmi, sq, txn, IPA_QMI_FILTER_INSTALLED_NOTIF,
				IPA_QMI_FILTER_INSTALLED_NOTIF_RSP_SZ,
				ipa_filter_installed_notif_rsp_ei, &rsp);
	if (ret)
		dev_err(ipa->dev,
			"error %d sending filter installed notif response\\n",
			ret);
}

/* The server handles four request message types sent by the modem. */
static const struct qmi_msg_handler ipa_server_msg_handlers[] = {
""", "qmi.c: handlers")
ok &= r

# register the two handlers in the table (insert before DRIVER_INIT_COMPLETE entry)
t, r = sub1(t,
"""	{
		.type		= QMI_REQUEST,
		.msg_id		= IPA_QMI_DRIVER_INIT_COMPLETE,
""",
"""	{
		.type		= QMI_REQUEST,
		.msg_id		= IPA_QMI_INSTALL_FILTER_RULE,
		.ei		= ipa_install_filter_rule_req_ei,
		.decoded_size	= IPA_QMI_INSTALL_FILTER_RULE_REQ_SZ,
		.fn		= ipa_server_install_filter_rule,
	},
	{
		.type		= QMI_REQUEST,
		.msg_id		= IPA_QMI_FILTER_INSTALLED_NOTIF,
		.ei		= ipa_filter_installed_notif_req_ei,
		.decoded_size	= IPA_QMI_FILTER_INSTALLED_NOTIF_REQ_SZ,
		.fn		= ipa_server_filter_installed_notif,
	},
	{
		.type		= QMI_REQUEST,
		.msg_id		= IPA_QMI_DRIVER_INIT_COMPLETE,
""", "qmi.c: register handlers")
ok &= r

open(p, "w").write(t)

print()
print("=== Step 1a applied (all_ok=%s) ===" % ok)
