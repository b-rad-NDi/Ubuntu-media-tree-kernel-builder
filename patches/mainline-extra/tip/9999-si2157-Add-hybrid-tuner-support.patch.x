From patchwork Fri Jan 12 16:19:38 2018
Subject: [3/7] si2157: Add hybrid tuner support
From: Brad Love <brad@nextdimension.cc>
X-Patchwork-Id: 46459

Add ability to share a tuner amongst demodulators. Addtional
demods are attached using hybrid_tuner_instance_list.

The changes are equivalent to moving all of probe to _attach.
Results are backwards compatible with current usage.

If the tuner is acquired via attach, then .release cleans state.
if the tuner is an i2c driver, then .release is set to NULL, and
.remove cleans remaining state.

The following file contains a static si2157_attach:
- drivers/media/pci/saa7164/saa7164-dvb.c
The function name has been appended with _priv to appease
the compiler.

Signed-off-by: Brad Love <brad@nextdimension.cc>
---
 drivers/media/pci/saa7164/saa7164-dvb.c |  11 +-
 drivers/media/tuners/si2157.c           | 232 +++++++++++++++++++++++---------
 drivers/media/tuners/si2157.h           |  14 ++
 drivers/media/tuners/si2157_priv.h      |   5 +
 4 files changed, 192 insertions(+), 70 deletions(-)

diff --git a/drivers/media/pci/saa7164/saa7164-dvb.c b/drivers/media/pci/saa7164/saa7164-dvb.c
index e76d3ba..9522c6c 100644
--- a/drivers/media/pci/saa7164/saa7164-dvb.c
+++ b/drivers/media/pci/saa7164/saa7164-dvb.c
@@ -110,8 +110,9 @@ static struct si2157_config hauppauge_hvr2255_tuner_config = {
 	.if_port = 1,
 };
 
-static int si2157_attach(struct saa7164_port *port, struct i2c_adapter *adapter,
-	struct dvb_frontend *fe, u8 addr8bit, struct si2157_config *cfg)
+static int si2157_attach_priv(struct saa7164_port *port,
+	struct i2c_adapter *adapter, struct dvb_frontend *fe,
+	u8 addr8bit, struct si2157_config *cfg)
 {
 	struct i2c_board_info bi;
 	struct i2c_client *tuner;
@@ -624,11 +625,13 @@ int saa7164_dvb_register(struct saa7164_port *port)
 		if (port->dvb.frontend != NULL) {
 
 			if (port->nr == 0) {
-				si2157_attach(port, &dev->i2c_bus[0].i2c_adap,
+				si2157_attach_priv(port,
+					      &dev->i2c_bus[0].i2c_adap,
 					      port->dvb.frontend, 0xc0,
 					      &hauppauge_hvr2255_tuner_config);
 			} else {
-				si2157_attach(port, &dev->i2c_bus[1].i2c_adap,
+				si2157_attach_priv(port,
+					      &dev->i2c_bus[1].i2c_adap,
 					      port->dvb.frontend, 0xc0,
 					      &hauppauge_hvr2255_tuner_config);
 			}
diff --git a/drivers/media/tuners/si2157.c b/drivers/media/tuners/si2157.c
index e35b1fa..9121361 100644
--- a/drivers/media/tuners/si2157.c
+++ b/drivers/media/tuners/si2157.c
@@ -18,6 +18,11 @@
 
 static const struct dvb_tuner_ops si2157_ops;
 
+static DEFINE_MUTEX(si2157_list_mutex);
+static LIST_HEAD(hybrid_tuner_instance_list);
+
+/*---------------------------------------------------------------------*/
+
 /* execute firmware command */
 static int si2157_cmd_execute(struct i2c_client *client, struct si2157_cmd *cmd)
 {
@@ -385,6 +390,31 @@ static int si2157_get_if_frequency(struct dvb_frontend *fe, u32 *frequency)
 	return 0;
 }
 
+static void si2157_release(struct dvb_frontend *fe)
+{
+	struct i2c_client *client = fe->tuner_priv;
+	struct si2157_dev *dev = i2c_get_clientdata(client);
+
+	dev_dbg(&client->dev, "%s()\n", __func__);
+
+	/* only do full cleanup on final instance */
+	if (hybrid_tuner_report_instance_count(dev) == 1) {
+		/* stop statistics polling */
+		cancel_delayed_work_sync(&dev->stat_work);
+#ifdef CONFIG_MEDIA_CONTROLLER_DVB
+		if (dev->mdev)
+			media_device_unregister_entity(&dev->ent);
+#endif
+		i2c_set_clientdata(client, NULL);
+	}
+
+	mutex_lock(&si2157_list_mutex);
+	hybrid_tuner_release_state(dev);
+	mutex_unlock(&si2157_list_mutex);
+
+	fe->tuner_priv = NULL;
+}
+
 static const struct dvb_tuner_ops si2157_ops = {
 	.info = {
 		.name           = "Silicon Labs Si2141/Si2146/2147/2148/2157/2158",
@@ -396,6 +426,7 @@ static const struct dvb_tuner_ops si2157_ops = {
 	.sleep = si2157_sleep,
 	.set_params = si2157_set_params,
 	.get_if_frequency = si2157_get_if_frequency,
+	.release = si2157_release,
 };
 
 static void si2157_stat_work(struct work_struct *work)
@@ -431,72 +462,30 @@ static int si2157_probe(struct i2c_client *client,
 {
 	struct si2157_config *cfg = client->dev.platform_data;
 	struct dvb_frontend *fe = cfg->fe;
-	struct si2157_dev *dev;
-	struct si2157_cmd cmd;
-	int ret;
-
-	dev = kzalloc(sizeof(*dev), GFP_KERNEL);
-	if (!dev) {
-		ret = -ENOMEM;
-		dev_err(&client->dev, "kzalloc() failed\n");
-		goto err;
-	}
-
-	i2c_set_clientdata(client, dev);
-	dev->fe = cfg->fe;
-	dev->inversion = cfg->inversion;
-	dev->if_port = cfg->if_port;
-	dev->chiptype = (u8)id->driver_data;
-	dev->if_frequency = 5000000; /* default value of property 0x0706 */
-	mutex_init(&dev->i2c_mutex);
-	INIT_DELAYED_WORK(&dev->stat_work, si2157_stat_work);
+	struct si2157_dev *dev = NULL;
+	unsigned short addr = client->addr;
+	int ret = 0;
 
-	/* check if the tuner is there */
-	cmd.wlen = 0;
-	cmd.rlen = 1;
-	ret = si2157_cmd_execute(client, &cmd);
-	if (ret)
-		goto err_kfree;
-
-	memcpy(&fe->ops.tuner_ops, &si2157_ops, sizeof(struct dvb_tuner_ops));
+	dev_dbg(&client->dev, "Probing tuner\n");
 	fe->tuner_priv = client;
 
-#ifdef CONFIG_MEDIA_CONTROLLER
-	if (cfg->mdev) {
-		dev->mdev = cfg->mdev;
-
-		dev->ent.name = KBUILD_MODNAME;
-		dev->ent.function = MEDIA_ENT_F_TUNER;
-
-		dev->pad[TUNER_PAD_RF_INPUT].flags = MEDIA_PAD_FL_SINK;
-		dev->pad[TUNER_PAD_OUTPUT].flags = MEDIA_PAD_FL_SOURCE;
-		dev->pad[TUNER_PAD_AUD_OUT].flags = MEDIA_PAD_FL_SOURCE;
-
-		ret = media_entity_pads_init(&dev->ent, TUNER_NUM_PADS,
-					     &dev->pad[0]);
-
-		if (ret)
-			goto err_kfree;
-
-		ret = media_device_register_entity(cfg->mdev, &dev->ent);
-		if (ret) {
-			media_entity_cleanup(&dev->ent);
-			goto err_kfree;
-		}
+	if (si2157_attach(fe, (u8)addr, client->adapter, cfg) == NULL) {
+		dev_err(&client->dev, "%s: attaching si2157 tuner failed\n",
+				__func__);
+		goto err;
 	}
-#endif
+	fe->ops.tuner_ops.release = NULL;
 
+	dev = i2c_get_clientdata(client);
+	dev->chiptype = (u8)id->driver_data;
 	dev_info(&client->dev, "Silicon Labs %s successfully attached\n",
 			dev->chiptype == SI2157_CHIPTYPE_SI2141 ?  "Si2141" :
 			dev->chiptype == SI2157_CHIPTYPE_SI2146 ?
 			"Si2146" : "Si2147/2148/2157/2158");
 
 	return 0;
-
-err_kfree:
-	kfree(dev);
 err:
-	dev_dbg(&client->dev, "failed=%d\n", ret);
+	dev_warn(&client->dev, "probe failed = %d\n", ret);
 	return ret;
 }
 
@@ -505,19 +494,10 @@ static int si2157_remove(struct i2c_client *client)
 	struct si2157_dev *dev = i2c_get_clientdata(client);
 	struct dvb_frontend *fe = dev->fe;
 
-	dev_dbg(&client->dev, "\n");
-
-	/* stop statistics polling */
-	cancel_delayed_work_sync(&dev->stat_work);
-
-#ifdef CONFIG_MEDIA_CONTROLLER_DVB
-	if (dev->mdev)
-		media_device_unregister_entity(&dev->ent);
-#endif
+	dev_dbg(&client->dev, "%s()\n", __func__);
 
 	memset(&fe->ops.tuner_ops, 0, sizeof(struct dvb_tuner_ops));
-	fe->tuner_priv = NULL;
-	kfree(dev);
+	si2157_release(fe);
 
 	return 0;
 }
@@ -542,7 +522,127 @@ static struct i2c_driver si2157_driver = {
 
 module_i2c_driver(si2157_driver);
 
-MODULE_DESCRIPTION("Silicon Labs Si2141/Si2146/2147/2148/2157/2158 silicon tuner driver");
+struct dvb_frontend *si2157_attach(struct dvb_frontend *fe, u8 addr,
+		struct i2c_adapter *i2c,
+		struct si2157_config *cfg)
+{
+	struct i2c_client *client = NULL;
+	struct si2157_dev *dev = NULL;
+	struct si2157_cmd cmd;
+	int instance = 0, ret;
+
+	pr_debug("%s (%d-%04x)\n", __func__,
+	       i2c ? i2c_adapter_id(i2c) : 0,
+	       addr);
+
+	if (!cfg) {
+		pr_warn("no configuration submitted\n");
+		goto fail;
+	}
+
+	if (!fe) {
+		pr_warn("fe is NULL\n");
+		goto fail;
+	}
+
+	client = fe->tuner_priv;
+	if (!client) {
+		pr_warn("client is NULL\n");
+		goto fail;
+	}
+
+	mutex_lock(&si2157_list_mutex);
+
+	instance = hybrid_tuner_request_state(struct si2157_dev, dev,
+			hybrid_tuner_instance_list,
+			i2c, addr, "si2157");
+
+	switch (instance) {
+	case 0:
+		goto fail;
+	case 1:
+		/* new tuner instance */
+		dev_dbg(&client->dev, "%s(): new instance for tuner @0x%02x\n",
+				__func__, addr);
+		dev->addr = addr;
+		i2c_set_clientdata(client, dev);
+
+		dev->fe = fe;
+		dev->chiptype = SI2157_CHIPTYPE_SI2157;
+		dev->if_frequency = 0;
+		dev->if_port   = cfg->if_port;
+		dev->inversion = cfg->inversion;
+
+		mutex_init(&dev->i2c_mutex);
+		INIT_DELAYED_WORK(&dev->stat_work, si2157_stat_work);
+
+		break;
+	default:
+		/* existing tuner instance */
+		dev_dbg(&client->dev,
+				"%s(): using existing instance for tuner @0x%02x\n",
+				 __func__, addr);
+		break;
+	}
+
+	/* check if the tuner is there */
+	cmd.wlen = 0;
+	cmd.rlen = 1;
+	ret = si2157_cmd_execute(client, &cmd);
+	/* verify no i2c error and CTS is set */
+	if (ret) {
+		dev_warn(&client->dev, "no HW found ret=%d\n", ret);
+		goto fail_instance;
+	}
+
+	memcpy(&fe->ops.tuner_ops, &si2157_ops, sizeof(struct dvb_tuner_ops));
+
+#ifdef CONFIG_MEDIA_CONTROLLER
+	if (instance == 1 && cfg->mdev) {
+		dev->mdev = cfg->mdev;
+
+		dev->ent.name = KBUILD_MODNAME;
+		dev->ent.function = MEDIA_ENT_F_TUNER;
+
+		dev->pad[TUNER_PAD_RF_INPUT].flags = MEDIA_PAD_FL_SINK;
+		dev->pad[TUNER_PAD_OUTPUT].flags = MEDIA_PAD_FL_SOURCE;
+		dev->pad[TUNER_PAD_AUD_OUT].flags = MEDIA_PAD_FL_SOURCE;
+
+		ret = media_entity_pads_init(&dev->ent, TUNER_NUM_PADS,
+					     &dev->pad[0]);
+
+		if (ret)
+			goto fail_instance;
+
+		ret = media_device_register_entity(cfg->mdev, &dev->ent);
+		if (ret) {
+			dev_warn(&client->dev,
+				"media_device_regiser_entity returns %d\n", ret);
+			media_entity_cleanup(&dev->ent);
+			goto fail_instance;
+		}
+	}
+#endif
+	mutex_unlock(&si2157_list_mutex);
+
+	if (instance != 1)
+		dev_info(&client->dev, "Silicon Labs %s successfully attached\n",
+			dev->chiptype == SI2157_CHIPTYPE_SI2141 ?  "Si2141" :
+			dev->chiptype == SI2157_CHIPTYPE_SI2146 ?
+			"Si2146" : "Si2147/2148/2157/2158");
+
+	return fe;
+fail_instance:
+	mutex_unlock(&si2157_list_mutex);
+
+	si2157_release(fe);
+fail:
+	dev_warn(&client->dev, "Attach failed\n");
+	return NULL;
+}
+EXPORT_SYMBOL(si2157_attach);
+
+MODULE_DESCRIPTION("Silicon Labs Si2141/2146/2147/2148/2157/2158 silicon tuner driver");
 MODULE_AUTHOR("Antti Palosaari <crope@iki.fi>");
 MODULE_LICENSE("GPL");
 MODULE_FIRMWARE(SI2158_A20_FIRMWARE);
diff --git a/drivers/media/tuners/si2157.h b/drivers/media/tuners/si2157.h
index de597fa..26b94ca 100644
--- a/drivers/media/tuners/si2157.h
+++ b/drivers/media/tuners/si2157.h
@@ -46,4 +46,18 @@ struct si2157_config {
 	u8 if_port;
 };
 
+#if IS_REACHABLE(CONFIG_MEDIA_TUNER_SI2157)
+extern struct dvb_frontend *si2157_attach(struct dvb_frontend *fe, u8 addr,
+					    struct i2c_adapter *i2c,
+					    struct si2157_config *cfg);
+#else
+static inline struct dvb_frontend *si2157_attach(struct dvb_frontend *fe,
+						   u8 addr,
+						   struct i2c_adapter *i2c,
+						   struct si2157_config *cfg)
+{
+	pr_err("%s: driver disabled by Kconfig\n", __func__);
+	return NULL;
+}
+#endif
 #endif
diff --git a/drivers/media/tuners/si2157_priv.h b/drivers/media/tuners/si2157_priv.h
index e6436f7..2801aaa 100644
--- a/drivers/media/tuners/si2157_priv.h
+++ b/drivers/media/tuners/si2157_priv.h
@@ -19,15 +19,20 @@
 
 #include <linux/firmware.h>
 #include <media/v4l2-mc.h>
+#include "tuner-i2c.h"
 #include "si2157.h"
 
 /* state struct */
 struct si2157_dev {
+	struct list_head hybrid_tuner_instance_list;
+	struct tuner_i2c_props  i2c_props;
+
 	struct mutex i2c_mutex;
 	struct dvb_frontend *fe;
 	bool active;
 	bool inversion;
 	u8 chiptype;
+	u8 addr;
 	u8 if_port;
 	u32 if_frequency;
 	struct delayed_work stat_work;
