// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * acer-sfx14-51g-platform.c
 *
 * Deliberately model-specific platform support for Acer Swift SFX14-51G.
 * No raw EC access, no fan setters, no arbitrary firmware passthrough.
 */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/acpi.h>
#include <linux/delay.h>
#include <linux/dmi.h>
#include <linux/hwmon.h>
#include <linux/init.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/platform_profile.h>
#include <linux/slab.h>
#include <linux/unaligned.h>
#include <linux/wmi.h>

#define DRV_NAME "acer-sfx14-51g-platform"

#define ACER_BATTERY_GUID "79772EC5-04B1-4BFD-843C-61E7F77B6CC9"
#define ACER_PROFILE_GUID "61EF69EA-865C-4BC3-A502-A0DEBA0CB531"
#define ACER_BH_GUID      "7A4DDFE7-5B5D-40B4-8595-4408E0CC7F56"

#define BATTERY_GET_METHOD 20
#define BATTERY_SET_METHOD 21
#define BATTERY_HEALTH_BIT BIT(0)
#define BATTERY_CALIB_BIT  BIT(1)

#define PROFILE_FUNCTION_ID 0x07
#define PROFILE_SET_METHOD  0x01
#define PROFILE_GET_METHOD  0x02
#define PROFILE_BALANCED    0x00
#define PROFILE_QUIET       0x02
#define PROFILE_PERFORMANCE 0x03

#define BH_GET_SYS_INFO 0x05
#define BH_GROUP_TEMP   0x01
#define BH_TEMP_CPU_SIDE 0x01
#define BH_TEMP_AMBIENT  0x03
#define BH_TEMP_GPU_SIDE 0x0a

#define ACER_ARTG_PATH "\\_SB.TPWR.ARTG"
#define ACER_ADAPTER_RATING_MAX_MW 255000ULL

struct acer_battery_get_request {
	u8 battery_no;
	u8 function_query;
	u8 reserved[2];
} __packed;

struct acer_battery_get_response {
	u8 function_list;
	u8 result[2];
	u8 function_status[5];
} __packed;

struct acer_battery_set_request {
	u8 battery_no;
	u8 function_mask;
	u8 function_status;
	u8 reserved[5];
} __packed;

struct acer_battery_set_response {
	u8 firmware_return;
	u8 reserved;
} __packed;

struct acer_profile_request {
	u8 function_id;
	u8 function_argument;
	u8 profile_id;
	u8 reserved;
} __packed;

struct acer_profile_response {
	u8 status;
	u8 profile_id;
	u8 capabilities;
	u8 reserved;
} __packed;

struct acer_sfx14_data {
	struct device *dev;
	struct mutex firmware_lock;
	struct device *profile_dev;
	struct device *hwmon_dev;
	bool health_available;
	bool calibration_available;
	long temp_cache[3];
	unsigned long temp_cache_jiffies[3];
	bool temp_cache_valid[3];
};

static struct platform_device *acer_sfx14_pdev;

static const struct dmi_system_id acer_sfx14_dmi[] = {
	{
		.ident = "Acer Swift SFX14-51G",
		.matches = {
			DMI_EXACT_MATCH(DMI_SYS_VENDOR, "Acer"),
			DMI_EXACT_MATCH(DMI_PRODUCT_NAME, "Swift SFX14-51G"),
		},
	},
	{}
};
MODULE_DEVICE_TABLE(dmi, acer_sfx14_dmi);

static int acer_wmi_eval_buffer(const char *guid, u32 method,
				const void *request, size_t request_len,
				void *response, size_t response_len)
{
	struct acpi_buffer input = {
		.length = request_len,
		.pointer = (void *)request,
	};
	struct acpi_buffer output = {
		.length = ACPI_ALLOCATE_BUFFER,
		.pointer = NULL,
	};
	union acpi_object *obj;
	acpi_status status;
	int ret = 0;

	status = wmi_evaluate_method(guid, 0, method, &input, &output);
	if (ACPI_FAILURE(status))
		return -EIO;

	obj = output.pointer;
	if (!obj) {
		ret = -ENODATA;
		goto out;
	}
	if (obj->type != ACPI_TYPE_BUFFER) {
		ret = -EPROTO;
		goto out;
	}
	if (!obj->buffer.pointer || obj->buffer.length < response_len) {
		pr_err("WMI %s method %u returned %u bytes, expected at least %zu\n",
		       guid, method, obj->buffer.length, response_len);
		ret = -EMSGSIZE;
		goto out;
	}
	memcpy(response, obj->buffer.pointer, response_len);
out:
	kfree(output.pointer);
	return ret;
}

static int acer_battery_get_locked(struct acer_sfx14_data *data,
				   bool *health, bool *calibration)
{
	const struct acer_battery_get_request request = {
		.battery_no = 1,
		.function_query = 1,
	};
	struct acer_battery_get_response response;
	int ret;

	ret = acer_wmi_eval_buffer(ACER_BATTERY_GUID, BATTERY_GET_METHOD,
				   &request, sizeof(request),
				   &response, sizeof(response));
	if (ret)
		return ret;

	data->health_available = response.function_list & BATTERY_HEALTH_BIT;
	data->calibration_available = response.function_list & BATTERY_CALIB_BIT;
	if (health)
		*health = data->health_available && response.function_status[0];
	if (calibration)
		*calibration = data->calibration_available && response.function_status[1];
	return 0;
}

static int acer_battery_set_locked(struct acer_sfx14_data *data,
				   u8 function, bool enabled)
{
	const struct acer_battery_set_request request = {
		.battery_no = 1,
		.function_mask = function,
		.function_status = enabled,
	};
	struct acer_battery_set_response response;
	bool health, calibration, observed;
	int ret;

	/*
	 * A successful
	 * WMI transaction plus a correctly shaped response means the command
	 * was accepted.  The first byte is firmware-owned return data, not a
	 * reliable errno; treating a nonzero value as -EIO caused false failures
	 * even when a following getter showed that the requested state applied.
	 */
	ret = acer_wmi_eval_buffer(ACER_BATTERY_GUID, BATTERY_SET_METHOD,
				   &request, sizeof(request),
				   &response, sizeof(response));
	if (ret)
		return ret;

	/* Refresh availability/state, but do not turn firmware settling into a
	 * failed sysfs write. Every show operation performs a fresh getter too.
	 */
	ret = acer_battery_get_locked(data, &health, &calibration);
	if (ret)
		return ret;

	observed = function == BATTERY_HEALTH_BIT ? health : calibration;
	if (observed != enabled)
		dev_dbg(data->dev,
			"battery function %#x requested %u, immediate read-back %u (firmware return %#x)\n",
			function, enabled, observed, response.firmware_return);

	return 0;
}

/*
 * APGe/WMAA profile transport
 * exposed here through the standard Linux platform_profile subsystem.  Keep
 * the minimum-length response rule because this firmware may append padding.
 */
static int acer_profile_eval_locked(u32 method, u8 profile_id,
				    struct acer_profile_response *response)
{
	const struct acer_profile_request request = {
		.function_id = PROFILE_FUNCTION_ID,
		.profile_id = profile_id,
	};
	int ret;

	ret = acer_wmi_eval_buffer(ACER_PROFILE_GUID, method,
				   &request, sizeof(request),
				   response, sizeof(*response));
	if (ret)
		return ret;
	return response->status ? -EIO : 0;
}

static int acer_profile_to_kernel(u8 id, enum platform_profile_option *profile)
{
	switch (id) {
	case PROFILE_QUIET:
		*profile = PLATFORM_PROFILE_QUIET;
		return 0;
	case PROFILE_BALANCED:
		*profile = PLATFORM_PROFILE_BALANCED;
		return 0;
	case PROFILE_PERFORMANCE:
		*profile = PLATFORM_PROFILE_PERFORMANCE;
		return 0;
	default:
		return -EPROTO;
	}
}

static int acer_profile_from_kernel(enum platform_profile_option profile, u8 *id)
{
	switch (profile) {
	case PLATFORM_PROFILE_QUIET:
		*id = PROFILE_QUIET;
		return 0;
	case PLATFORM_PROFILE_BALANCED:
		*id = PROFILE_BALANCED;
		return 0;
	case PLATFORM_PROFILE_PERFORMANCE:
		*id = PROFILE_PERFORMANCE;
		return 0;
	default:
		return -EOPNOTSUPP;
	}
}

static int acer_profile_probe(void *drvdata, unsigned long *choices)
{
	set_bit(PLATFORM_PROFILE_QUIET, choices);
	set_bit(PLATFORM_PROFILE_BALANCED, choices);
	set_bit(PLATFORM_PROFILE_PERFORMANCE, choices);
	return 0;
}

static int acer_profile_get(struct device *dev,
			    enum platform_profile_option *profile)
{
	struct acer_sfx14_data *data = dev_get_drvdata(dev);
	struct acer_profile_response response;
	int ret;

	mutex_lock(&data->firmware_lock);
	ret = acer_profile_eval_locked(PROFILE_GET_METHOD, 0, &response);
	mutex_unlock(&data->firmware_lock);
	if (ret)
		return ret;
	return acer_profile_to_kernel(response.profile_id, profile);
}

static int acer_profile_set(struct device *dev,
			    enum platform_profile_option profile)
{
	struct acer_sfx14_data *data = dev_get_drvdata(dev);
	struct acer_profile_response response;
	enum platform_profile_option observed;
	u8 id;
	int ret;

	ret = acer_profile_from_kernel(profile, &id);
	if (ret)
		return ret;

	mutex_lock(&data->firmware_lock);
	ret = acer_profile_eval_locked(PROFILE_SET_METHOD, id, &response);
	if (!ret) {
		ret = acer_profile_eval_locked(PROFILE_GET_METHOD, 0, &response);
		if (!ret) {
			ret = acer_profile_to_kernel(response.profile_id, &observed);
			if (!ret && observed != profile)
				ret = -EIO;
		}
	}
	mutex_unlock(&data->firmware_lock);
	return ret;
}

static const struct platform_profile_ops acer_profile_ops = {
	.probe = acer_profile_probe,
	.profile_get = acer_profile_get,
	.profile_set = acer_profile_set,
};

static int acer_bh_temp_locked(u8 selector, long *millideg)
{
	const u8 request[4] = { BH_GROUP_TEMP, selector, 0, 0 };
	u8 response[8];
	u16 value;
	int ret;

	ret = acer_wmi_eval_buffer(ACER_BH_GUID, BH_GET_SYS_INFO,
				   request, sizeof(request),
				   response, sizeof(response));
	if (ret)
		return ret;
	if (response[0])
		return -EIO;
	value = get_unaligned_le16(&response[1]);
	if (value < 10 || value > 120)
		return -ERANGE;
	*millideg = value * 1000L;
	return 0;
}

static int acer_bh_temp_retry_locked(u8 selector, long *millideg)
{
	int ret;

	ret = acer_bh_temp_locked(selector, millideg);
	if (ret == -ERANGE || ret == -EIO) {
		usleep_range(5000, 7000);
		ret = acer_bh_temp_locked(selector, millideg);
	}
	if (ret == -ERANGE || ret == -EIO) {
		usleep_range(10000, 12000);
		ret = acer_bh_temp_locked(selector, millideg);
	}

	return ret;
}

static int acer_adapter_rating_mw_locked(unsigned long *rating_mw)
{
	unsigned long long value;
	acpi_status status;

	status = acpi_evaluate_integer(NULL, ACER_ARTG_PATH, NULL, &value);
	if (ACPI_FAILURE(status))
		return -EIO;

	/*
	 * ARTG returns 0 when no PSU is connected.  Otherwise it returns
	 * the 8-bit EC ADPW value multiplied by 1000, in milliwatts.
	 */
	if (value > ACER_ADAPTER_RATING_MAX_MW)
		return -ERANGE;

	*rating_mw = value;
	return 0;
}

static umode_t acer_hwmon_is_visible(const void *drvdata,
				     enum hwmon_sensor_types type,
				     u32 attr, int channel)
{
	if (type == hwmon_temp && (attr == hwmon_temp_input ||
				    attr == hwmon_temp_label) && channel < 3)
		return 0444;
	if (type == hwmon_power && (attr == hwmon_power_input ||
				     attr == hwmon_power_label) && channel == 0)
		return 0444;
	return 0;
}

static int acer_hwmon_read(struct device *dev, enum hwmon_sensor_types type,
			   u32 attr, int channel, long *value)
{
	static const u8 selectors[] = {
		BH_TEMP_CPU_SIDE, BH_TEMP_GPU_SIDE, BH_TEMP_AMBIENT,
	};
	struct acer_sfx14_data *data = dev_get_drvdata(dev);
	unsigned long rating_mw;
	int ret;

	if (type == hwmon_power && attr == hwmon_power_input && channel == 0) {
		mutex_lock(&data->firmware_lock);
		ret = acer_adapter_rating_mw_locked(&rating_mw);
		mutex_unlock(&data->firmware_lock);
		if (ret)
			return ret;

		/* The hwmon power ABI exposes power values in microwatts. */
		*value = rating_mw * 1000UL;
		return 0;
	}

	if (type != hwmon_temp || attr != hwmon_temp_input || channel >= ARRAY_SIZE(selectors))
		return -EOPNOTSUPP;
	mutex_lock(&data->firmware_lock);
	/* TSR1 can transiently read as zero; do not publish bogus 0 C. */
	ret = acer_bh_temp_retry_locked(selectors[channel], value);

	if (!ret) {
		data->temp_cache[channel] = *value;
		data->temp_cache_jiffies[channel] = jiffies;
		data->temp_cache_valid[channel] = true;
	} else if ((ret == -ERANGE || ret == -EIO) &&
		   data->temp_cache_valid[channel] &&
		   time_before(jiffies,
			       data->temp_cache_jiffies[channel] + 2 * HZ)) {
		/* Use a last-good sample for at most two seconds. */
		*value = data->temp_cache[channel];
		ret = 0;
	}
	mutex_unlock(&data->firmware_lock);
	return ret;
}

static int acer_hwmon_read_string(struct device *dev,
				  enum hwmon_sensor_types type,
				  u32 attr, int channel,
				  const char **str)
{
	static const char * const labels[] = {
		"CPU-side", "GPU-side", "Internal ambient",
	};

	if (type == hwmon_power && attr == hwmon_power_label && channel == 0) {
		*str = "Connected PSU rating";
		return 0;
	}
	if (type != hwmon_temp || attr != hwmon_temp_label || channel >= ARRAY_SIZE(labels))
		return -EOPNOTSUPP;
	*str = labels[channel];
	return 0;
}

static const struct hwmon_ops acer_hwmon_ops = {
	.is_visible = acer_hwmon_is_visible,
	.read = acer_hwmon_read,
	.read_string = acer_hwmon_read_string,
};

static const struct hwmon_channel_info * const acer_hwmon_info[] = {
	HWMON_CHANNEL_INFO(temp,
		HWMON_T_INPUT | HWMON_T_LABEL,
		HWMON_T_INPUT | HWMON_T_LABEL,
		HWMON_T_INPUT | HWMON_T_LABEL),
	HWMON_CHANNEL_INFO(power,
		HWMON_P_INPUT | HWMON_P_LABEL),
	NULL
};

static const struct hwmon_chip_info acer_hwmon_chip_info = {
	.ops = &acer_hwmon_ops,
	.info = acer_hwmon_info,
};

static ssize_t battery_mode_show(struct device *dev, bool health_mode, char *buf)
{
	struct acer_sfx14_data *data = dev_get_drvdata(dev);
	bool health, calibration, value;
	int ret;

	mutex_lock(&data->firmware_lock);
	ret = acer_battery_get_locked(data, &health, &calibration);
	mutex_unlock(&data->firmware_lock);
	if (ret)
		return ret;
	if ((health_mode && !data->health_available) ||
	    (!health_mode && !data->calibration_available))
		return -EOPNOTSUPP;
	value = health_mode ? health : calibration;
	return sysfs_emit(buf, "%u\n", value);
}

static ssize_t battery_mode_store(struct device *dev, bool health_mode,
				  const char *buf, size_t count)
{
	struct acer_sfx14_data *data = dev_get_drvdata(dev);
	bool enabled;
	u8 function = health_mode ? BATTERY_HEALTH_BIT : BATTERY_CALIB_BIT;
	int ret;

	ret = kstrtobool(buf, &enabled);
	if (ret)
		return ret;
	mutex_lock(&data->firmware_lock);
	ret = acer_battery_get_locked(data, NULL, NULL);
	if (!ret && ((health_mode && !data->health_available) ||
		    (!health_mode && !data->calibration_available)))
		ret = -EOPNOTSUPP;
	if (!ret)
		ret = acer_battery_set_locked(data, function, enabled);
	mutex_unlock(&data->firmware_lock);
	return ret ? ret : count;
}

static ssize_t battery_health_mode_show(struct device *dev,
					struct device_attribute *attr, char *buf)
{
	return battery_mode_show(dev, true, buf);
}

static ssize_t battery_health_mode_store(struct device *dev,
					 struct device_attribute *attr,
					 const char *buf, size_t count)
{
	return battery_mode_store(dev, true, buf, count);
}
static DEVICE_ATTR_RW(battery_health_mode);

static ssize_t battery_calibration_mode_show(struct device *dev,
					     struct device_attribute *attr,
					     char *buf)
{
	return battery_mode_show(dev, false, buf);
}

static ssize_t battery_calibration_mode_store(struct device *dev,
					      struct device_attribute *attr,
					      const char *buf, size_t count)
{
	return battery_mode_store(dev, false, buf, count);
}
static DEVICE_ATTR_RW(battery_calibration_mode);

static ssize_t adapter_rating_mw_show(struct device *dev,
				      struct device_attribute *attr, char *buf)
{
	struct acer_sfx14_data *data = dev_get_drvdata(dev);
	unsigned long rating_mw;
	int ret;

	mutex_lock(&data->firmware_lock);
	ret = acer_adapter_rating_mw_locked(&rating_mw);
	mutex_unlock(&data->firmware_lock);
	if (ret)
		return ret;

	return sysfs_emit(buf, "%lu\n", rating_mw);
}
static DEVICE_ATTR_RO(adapter_rating_mw);

static struct attribute *acer_attrs[] = {
	&dev_attr_battery_health_mode.attr,
	&dev_attr_battery_calibration_mode.attr,
	&dev_attr_adapter_rating_mw.attr,
	NULL
};
static const struct attribute_group acer_group = {
	.attrs = acer_attrs,
};

static int acer_sfx14_probe(struct platform_device *pdev)
{
	struct acer_sfx14_data *data;
	struct acer_profile_response profile_response;
	long temp;
	int ret;

	if (!dmi_first_match(acer_sfx14_dmi))
		return -ENODEV;
	if (!wmi_has_guid(ACER_BATTERY_GUID) ||
	    !wmi_has_guid(ACER_PROFILE_GUID) ||
	    !wmi_has_guid(ACER_BH_GUID))
		return -ENODEV;

	data = devm_kzalloc(&pdev->dev, sizeof(*data), GFP_KERNEL);
	if (!data)
		return -ENOMEM;
	data->dev = &pdev->dev;
	mutex_init(&data->firmware_lock);
	platform_set_drvdata(pdev, data);

	mutex_lock(&data->firmware_lock);
	ret = acer_profile_eval_locked(PROFILE_GET_METHOD, 0, &profile_response);
	if (!ret)
		ret = acer_battery_get_locked(data, NULL, NULL);
	if (!ret)
		ret = acer_bh_temp_retry_locked(BH_TEMP_CPU_SIDE, &temp);
	mutex_unlock(&data->firmware_lock);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "firmware getter self-test failed\n");

	ret = devm_device_add_group(&pdev->dev, &acer_group);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "sysfs registration failed\n");

	data->profile_dev = devm_platform_profile_register(&pdev->dev,
		DRV_NAME, data, &acer_profile_ops);
	if (IS_ERR(data->profile_dev))
		return dev_err_probe(&pdev->dev, PTR_ERR(data->profile_dev),
				     "platform profile registration failed\n");

	data->hwmon_dev = devm_hwmon_device_register_with_info(&pdev->dev,
		"acer_sfx14_51g", data, &acer_hwmon_chip_info, NULL);
	if (IS_ERR(data->hwmon_dev))
		return dev_err_probe(&pdev->dev, PTR_ERR(data->hwmon_dev),
				     "hwmon registration failed\n");

	dev_info(&pdev->dev, "initialized: profile, battery controls, hwmon, adapter rating\n");
	return 0;
}

static struct platform_driver acer_sfx14_driver = {
	.driver = {
		.name = DRV_NAME,
	},
	.probe = acer_sfx14_probe,
};

static int __init acer_sfx14_init(void)
{
	int ret;

	if (!dmi_first_match(acer_sfx14_dmi))
		return -ENODEV;
	ret = platform_driver_register(&acer_sfx14_driver);
	if (ret)
		return ret;
	acer_sfx14_pdev = platform_device_register_simple(DRV_NAME,
						    PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(acer_sfx14_pdev)) {
		ret = PTR_ERR(acer_sfx14_pdev);
		platform_driver_unregister(&acer_sfx14_driver);
		return ret;
	}
	if (!platform_get_drvdata(acer_sfx14_pdev)) {
		pr_err("platform device was created but probe did not bind\n");
		platform_device_unregister(acer_sfx14_pdev);
		platform_driver_unregister(&acer_sfx14_driver);
		return -ENODEV;
	}
	return 0;
}

static void __exit acer_sfx14_exit(void)
{
	platform_device_unregister(acer_sfx14_pdev);
	platform_driver_unregister(&acer_sfx14_driver);
}

module_init(acer_sfx14_init);
module_exit(acer_sfx14_exit);

MODULE_DESCRIPTION("Acer Swift SFX14-51G platform profile, battery and sensor driver");
MODULE_AUTHOR("ciao986");
MODULE_LICENSE("GPL");
MODULE_VERSION("0.3.0");
MODULE_ALIAS("wmi:" ACER_BATTERY_GUID);
MODULE_ALIAS("wmi:" ACER_PROFILE_GUID);
MODULE_ALIAS("wmi:" ACER_BH_GUID);
